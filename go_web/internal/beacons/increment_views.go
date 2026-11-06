package beacons

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	// Link::ANALYTICS_VIEW_TOKEN_PURPOSE.
	analyticsViewPurpose = "external_landing_page_view"
	// LinksController::TRANSPARENT_1X1_GIF.
	transparentGIFBytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xFF\xFF\xFF!\xF9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
)

var transparentGIF = rails.NewStatic(transparentGIFBytes)

// ElasticsearchIndexerWorker's sidekiq_options over default_job_options.
var elasticsearchIndexer = sidekiq.Options{Class: "ElasticsearchIndexerWorker", Queue: "default", Retry: 10}

type product struct {
	id, userID int64
	priceCents sql.NullInt64
	// ownerExists is @product.user being present.
	ownerExists bool
}

// fetchProduct is ApplicationController#fetch_product: Link.fetch(params[:id]) or a 404.
func (h *handlers) fetchProduct(c *actionContext) (*product, error) {
	p := &product{}
	err := h.deps.DB.QueryRowContext(c.ctx, `SELECT links.id, links.user_id, links.price_cents, users.id IS NOT NULL
		FROM links LEFT JOIN users ON users.id = links.user_id
		WHERE (1 = 1) AND links.deleted_at IS NULL AND links.unique_permalink = ? LIMIT 1`, rails.ToS(c.req.Param("id"))).
		Scan(&p.id, &p.userID, &p.priceCents, &p.ownerExists)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	return p, err
}

// incrementViews is LinksController#increment_views. The analytics token is only checked
// once nothing else skips the view; the check has no side effects.
func (h *handlers) incrementViews(c *actionContext) error {
	product, err := h.fetchProduct(c)
	if err != nil {
		return err
	}
	req := c.req
	logged := c.auth.LoggedInUser()
	skip := rails.IsBot(req)
	if logged != nil {
		// A token's impersonation leaves current_seller nil, and current_seller.id raises.
		if c.auth.CurrentSeller == nil {
			return errors.New("undefined method 'id' for nil current_seller")
		}
		skip = skip || product.userID == c.auth.CurrentSeller.ID || logged.IsTeamMember()
	}
	skip = skip || c.auth.ImpersonatingUser() != nil
	var payload map[string]any
	if !skip && req.Get() {
		payload = h.analyticsViewPayload(req, product)
		skip = payload == nil
	}

	if !skip {
		var userID any
		if logged != nil {
			userID = logged.ID
		}
		var sourceURL any
		if payload != nil {
			sourceURL = payload["source_url"]
		}
		referrer := sourceURL
		if !rails.Truthy(referrer) {
			referrer = rails.LastPresent(req.Param("referrer"))
		}
		if !rails.Truthy(referrer) {
			referrer = stringOrNil(req.Referrer())
		}
		viewURL := sourceURL
		if !rails.Truthy(viewURL) {
			viewURL = req.Param("view_url")
		}
		if !rails.Truthy(viewURL) {
			viewURL = req.Path
		}
		var id string
		if req.Get() {
			sum := sha256.Sum256([]byte(strconv.FormatInt(product.id, 10) + "\x00" + rails.ToS(payload["event_id"])))
			id = hex.EncodeToString(sum[:])
		} else {
			id = web.NewUUID()
		}
		recommended := rails.BooleanCast(req.Param("was_product_recommended"))
		if err := h.createProductPageView(c, product, userID, referrer, recommended != nil && *recommended, viewURL, id); err != nil {
			return err
		}
	}

	if req.Format() == "gif" {
		// expires_now, then send_data(TRANSPARENT_1X1_GIF, type: "image/gif", disposition: "inline").
		c.w.Header().Set("Cache-Control", "no-cache")
		rails.SendStatic(c.w, req, "image/gif", transparentGIF)
	} else {
		rails.RenderStaticJSON(c.w, req, http.StatusOK, successTrue)
	}
	return nil
}

// analyticsViewPayload is Link#analytics_view_token_payload(params[:analytics_token],
// source_url: request.referrer).
func (h *handlers) analyticsViewPayload(req *rails.Request, product *product) map[string]any {
	data, ok := h.views.Verified(rails.ToS(req.Param("analytics_token")), analyticsViewPurpose, req.Now)
	if !ok {
		return nil
	}
	var payload map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if decoder.Decode(&payload) != nil || payload == nil {
		return nil
	}
	productID, _ := payload["product_id"].(json.Number)
	sourceURL, isString := payload["source_url"].(string)
	source := ""
	if r := req.Referrer(); r != nil {
		source = *r
	}
	if string(productID) != strconv.FormatInt(product.id, 10) || !isString || sourceURL != source || !rails.Present(payload["event_id"]) {
		return nil
	}
	return payload
}

// createProductPageView is ProductsHelper#create_product_page_view.
func (h *handlers) createProductPageView(c *actionContext, product *product, userID, referrer any, recommended bool, viewURL any, id string) error {
	req := c.req
	ip, err := req.RemoteIP()
	if err != nil {
		return err
	}
	geo := h.deps.GeoIP.Lookup(ip)
	referrer, err = asciiReferrer(referrer)
	if err != nil {
		return err
	}
	domain := recommendedReferrerDomain
	if !recommended {
		domain = referrerDomain(asStringPtr(referrer))
	}
	fingerprint, ok := browserFingerprint(req)
	if !ok {
		c.logger().Info("Skipping a product page view with a non-scalar plugins param")
		return nil
	}
	guid, _ := req.Cookie(guidCookie)
	var country, state any
	if geo != nil {
		country, state = stringOrNil(geo.CountryName), stringOrNil(geo.RegionName)
	}
	body := sidekiq.Hash{
		{Key: "product_id", Value: product.id},
		{Key: "country", Value: country},
		{Key: "state", Value: state},
		{Key: "referrer_domain", Value: domain},
		{Key: "timestamp", Value: req.Now.UTC().Format("2006-01-02T15:04:05Z07:00")},
		{Key: "seller_id", Value: product.userID},
		{Key: "user_id", Value: userID},
		{Key: "ip_address", Value: ip},
		{Key: "url", Value: viewURL},
		{Key: "browser_guid", Value: guid},
		{Key: "browser_fingerprint", Value: fingerprint},
		{Key: "referrer", Value: referrer},
	}
	// Sidekiq's strict args refuse ActionController::Parameters, so a hash view_url fails
	// Marshal as it raises in Rails.
	ctx, cancel := c.writeContext()
	defer cancel()
	_, err = h.deps.Sidekiq.Push(ctx, elasticsearchIndexer, "index", sidekiq.Hash{
		{Key: "class_name", Value: "ProductPageView"},
		{Key: "id", Value: id},
		{Key: "body", Value: body},
	})
	return err
}

// asciiReferrer is referrer.encode("ASCII", invalid: :replace, undef: :replace,
// replace: "")[0..190] for a present referrer; a non-String raises NoMethodError.
func asciiReferrer(v any) (any, error) {
	if !rails.Present(v) {
		return v, nil
	}
	s, isString := v.(string)
	if !isString {
		return nil, errors.New("undefined method 'encode' for the referrer param")
	}
	var b strings.Builder
	n := 0
	for _, r := range s {
		if r < 0x80 && n < maxReferrerLength {
			b.WriteRune(r)
			n++
		}
	}
	return b.String(), nil
}

// browserFingerprint is Digest::MD5.hexdigest([user_agent, params[:plugins]].join(",")).
// ok is false for a plugins param holding a hash, which callers skip the write for.
func browserFingerprint(req *rails.Request) (string, bool) {
	ua := ""
	if v := req.UserAgent(); v != nil {
		ua = *v
	}
	plugins, ok := rails.Join(req.Param("plugins"), ",")
	if !ok {
		return "", false
	}
	sum := md5.Sum([]byte(ua + "," + plugins))
	return hex.EncodeToString(sum[:]), true
}

func stringOrNil(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

func asStringPtr(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

func (c *actionContext) logger() *slog.Logger { return web.Logger(c.req.HTTP) }
