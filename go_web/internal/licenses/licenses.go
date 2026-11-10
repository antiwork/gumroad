// Package licenses replaces Api::V2::LicensesController#verify, which seller software calls to
// check a license key. Rails is the spec: every status, body and write here follows it.
package licenses

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/errorreport"
	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	action = "Api::V2::LicensesController#verify"

	// Inside main.go's 30s WriteTimeout.
	actionTimeout = 25 * time.Second

	// Real verify bodies are a few hundred bytes, and Go has no Puma thread cap to bound
	// what a flood of large ones costs.
	maxBodyBytes = 64 << 10

	forceProductIDTimestampKey = "force_product_id_timestamp"
	skipProductIDCheckPrefix   = "license_verifications:skip_product_id_check_"
)

// Deps are what the action reads. Redis is $redis (REDIS_HOST); SidekiqRedis is
// SIDEKIQ_REDIS_HOST, where the search reindex job is scheduled.
type Deps struct {
	Env          *web.Environment
	Stack        *rails.Stack
	DB           *sql.DB
	Redis        redis.Cmdable
	SidekiqRedis redis.Cmdable
	IDs          idDecoder
	// Proxy takes a request that carries SessionCookie, Rails' session cookie, whose
	// session filters (sign-out of invalidated sessions, check_suspended) this port leaves
	// out.
	Proxy         *web.RailsProxy
	SessionCookie string
}

type idDecoder interface {
	idEncoder
	Decrypt(external string) (int64, bool)
}

// Register routes POST /v2/licenses/verify(.:format), ApiDomainConstraint's mount, and
// /api/v2/licenses/verify(.:format), GumroadDomainConstraint's. A ServeMux wildcard must
// span a whole segment, so the format variant arrives as {file} and is checked here.
func Register(app *web.App, deps Deps) {
	register(app, deps, time.Now)
}

func register(app *web.App, deps Deps, now func() time.Time) *handler {
	h := &handler{
		cfg:     newConfig(deps.Env),
		stack:   deps.Stack,
		store:   &store{db: deps.DB},
		tokens:  &oauth.Store{DB: deps.DB, Users: &session.Users{DB: deps.DB}},
		redis:   deps.Redis,
		sidekiq: &sidekiq.Client{Redis: deps.SidekiqRedis, Now: now},
		ids:     deps.IDs,
		now:     now,
		proxy:   deps.Proxy,
		session: deps.SessionCookie,
	}
	for _, prefix := range []string{"/v2/licenses/", "/api/v2/licenses/"} {
		app.Handle("POST "+prefix+"verify", action, h)
		app.Handle("POST "+prefix+"{file}", action, h)
	}
	return h
}

type config struct {
	env *web.Environment
}

func newConfig(env *web.Environment) *config {
	return &config{env: env}
}

type handler struct {
	cfg     *config
	stack   *rails.Stack
	store   *store
	tokens  *oauth.Store
	redis   redis.Cmdable
	sidekiq *sidekiq.Client
	ids     idDecoder
	now     func() time.Time
	proxy   *web.RailsProxy
	session string

	// LicensesController.last_known_force_product_id_timestamp: per process, nil until read.
	mu                      sync.Mutex
	lastKnownForceProductTS *time.Time
}

var formatFile = regexp.MustCompile(`\Averify\.([^/.?]+)\z`)

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	format, ok := h.route(r)
	if !ok {
		h.stack.NotFound().ServeHTTP(w, r)
		return
	}
	// r.Cookie("") would match any cookie.
	if h.proxy != nil && h.session != "" {
		if _, err := r.Cookie(h.session); err == nil {
			h.proxy.Forward(w, r, "session cookie")
			return
		}
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	pathParams := [][2]string{{"controller", "api/v2/licenses"}, {"action", "verify"}}
	if format != "" {
		pathParams = append(pathParams, [2]string{"format", format})
	}
	req, err := h.stack.Parse(r, pathParams, h.now())
	if err != nil {
		h.parseError(w, r, err)
		return
	}
	// Puma finishes an action whether or not the client is still there, so a verify that
	// reached the app still counts its use.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), actionTimeout)
	defer cancel()
	if err := h.verify(ctx, w, req); err != nil {
		web.Logger(r).Error("License verification failed", "error", err.Error())
		rails.RenderException(w, req, http.StatusInternalServerError)
	}
}

// parseError answers params Rails can't read. A JSON ParseError surfaces only when a
// before_action reads params, and current_api_user runs first: a Bearer token whose owner is
// missing raises RecordNotFound there, a 404, before the 400 is reached.
func (h *handler) parseError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, rails.ErrParse) {
		noParams := func(string) any { return nil }
		if raw, ok := oauth.FromRequest(r.Header.Get("Authorization"), noParams); ok {
			ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), actionTimeout)
			defer cancel()
			token, lookupErr := h.tokens.Bound(ctx, raw, h.cfg.env.Protocol+"://"+h.cfg.env.Domain+r.URL.EscapedPath(), h.now())
			switch {
			case lookupErr != nil:
				web.Logger(r).Error("License verification failed", "error", lookupErr.Error())
				rails.RenderException(w, h.stack.Fallback(r), http.StatusInternalServerError)
				return
			case token != nil && token.Owner == nil:
				rails.RenderException(w, h.stack.Fallback(r), http.StatusNotFound)
				return
			}
		}
	}
	if !h.stack.RenderParseError(w, r, err) {
		rails.RenderException(w, h.stack.Fallback(r), http.StatusInternalServerError)
	}
}

// route reads the format off verify.<format> and applies the mount's host constraint.
func (h *handler) route(r *http.Request) (format string, ok bool) {
	if file := r.PathValue("file"); file != "" {
		m := formatFile.FindStringSubmatch(file)
		if m == nil {
			return "", false
		}
		format = m[1] // PathValue is already unescaped, as Journey unescapes path params
	}
	host := web.Host(r)
	if strings.HasPrefix(r.URL.Path, "/api/") {
		return format, slices.Contains(h.cfg.env.ValidRequestHosts, host)
	}
	return format, h.cfg.env.Name == "development" || slices.Contains(h.cfg.env.ValidAPIRequestHosts, host)
}

func errorBody(message string) string {
	return rails.EncodeJSON(rails.NewRHash().Sym("success", false).Sym("message", message))
}

// verify runs the controller's filters and action in order; each step that renders returns
// done, which halts the chain like a before_action render.
func (h *handler) verify(ctx context.Context, w http.ResponseWriter, req *rails.Request) error {
	// ApplicationController's before_actions resolve the API user (via logged_in_user) first.
	// current_api_user's User.find raises RecordNotFound for a token without its owner, before
	// a brand token's team member is ever looked at, so Owner decides rather than Actor.
	var token *oauth.Token
	if raw, ok := oauth.FromRequest(req.Header("Authorization"), req.Param); ok {
		var err error
		if token, err = h.tokens.Bound(ctx, raw, h.cfg.env.Protocol+"://"+h.cfg.env.Domain+req.Path, req.Now); err != nil {
			return err
		}
		if token != nil && token.Owner == nil {
			rails.RenderException(w, req, http.StatusNotFound)
			return nil
		}
	}

	cleaned, badKey := cleanParams(req)
	if badKey != "" {
		rails.RenderJSON(w, req, http.StatusBadRequest, errorBody("The '"+badKey+"' parameter must be a string."))
		return nil
	}
	lk, done, err := h.fetchValidLicense(ctx, w, req, cleaned)
	if done || err != nil {
		return err
	}

	// verify
	lic := lk.license
	if lic.disabledAt.Valid {
		rails.RenderJSON(w, req, http.StatusNotFound, errorBody("This license key has been disabled."))
		h.logMethodUse(ctx, req, token)
		return nil
	}
	if cleaned.incrementUses {
		if err := h.updateLicenseUses(ctx, req, lic); err != nil {
			return err
		}
	}
	if err := h.successWithLicense(ctx, w, req, lk); err != nil {
		return err
	}
	h.logMethodUse(ctx, req, token)
	return nil
}

type cleanedParams struct {
	productID     string // "" when blank
	licenseKey    any
	permalink     string // id, link_id, then product_permalink
	incrementUses bool
}

// cleanParams is the controller's clean_params; badKey names the first non-string identifier.
func cleanParams(req *rails.Request) (cleaned cleanedParams, badKey string) {
	for _, key := range []string{"license_key", "product_id", "product_permalink", "id", "link_id"} {
		if v := req.Param(key); rails.Present(v) {
			if _, isString := v.(string); !isString {
				return cleaned, key
			}
		}
	}
	for _, key := range []string{"id", "link_id", "product_permalink"} {
		if v := req.Param(key); rails.Present(v) {
			cleaned.permalink = v.(string)
			break
		}
	}
	if v := req.Param("product_id"); rails.Present(v) {
		cleaned.productID = v.(string)
	}
	cleaned.licenseKey = req.Param("license_key")
	increment := req.Param("increment_uses_count")
	cleaned.incrementUses = increment != "false" && increment != false
	return cleaned, ""
}

// fetchValidLicense is the controller's fetch_valid_license.
func (h *handler) fetchValidLicense(ctx context.Context, w http.ResponseWriter, req *rails.Request, p cleanedParams) (*lookup, bool, error) {
	var lk *lookup
	var err error
	if p.productID != "" {
		// Link.find_by_external_id: an id that doesn't decrypt finds no product. It still
		// queries, so how long the answer takes says nothing about the id's padding.
		id, ok := h.ids.Decrypt(p.productID)
		if !ok {
			id = noProductID
		}
		lk, err = h.store.findLicense(ctx, &id, p.licenseKey)
	} else {
		lk, err = h.store.findLicense(ctx, nil, p.licenseKey)
	}
	if err != nil {
		return nil, true, err
	}

	if p.productID == "" && lk != nil && lk.product != nil {
		skip, cutoff, err := h.productIDFlags(ctx, lk.product.id, req.Now)
		if err != nil {
			return nil, true, err
		}
		if !skip && cutoff != nil {
			prod := lk.product
			if !prod.createdAt.Valid {
				return nil, true, fmt.Errorf("link %d: %w (created_at)", prod.id, errMissingRecord)
			}
			if prod.createdAt.Time.After(*cutoff) {
				web.Logger(req.HTTP).Error("[License Verification Error] product_id missing, responding with HTTP 500 for product: "+itoa(prod.id), errorreport.LogOnly)
				message := "The 'product_id' parameter is required to verify the license for this product. " +
					"Please set 'product_id' to '" + h.ids.Encrypt(prod.id) + "' in the request."
				rails.RenderJSON(w, req, http.StatusInternalServerError, errorBody(message))
				return nil, true, nil
			}
		}
	}

	notFound := errorBody("That license does not exist for the provided product.")
	if lk == nil {
		rails.RenderJSON(w, req, http.StatusNotFound, notFound)
		return nil, true, nil
	}
	if p.productID == "" {
		if lk.product == nil {
			return nil, true, fmt.Errorf("license %d: %w (link)", lk.license.id, errMissingRecord)
		}
		if !matchesPermalink(lk.product, p.permalink) {
			rails.RenderJSON(w, req, http.StatusNotFound, notFound)
			return nil, true, nil
		}
	}
	if lk.purchase != nil && lk.purchase.is(purchaseIsAccessRevoked) {
		rails.RenderJSON(w, req, http.StatusNotFound, errorBody("Access to the purchase associated with this license has expired."))
		return nil, true, nil
	}
	return lk, false, nil
}

// noProductID is an id no product has.
const noProductID int64 = 0

// matchesPermalink is Link#matches_permalink?, which compares String#downcase of both.
func matchesPermalink(prod *product, permalink string) bool {
	return permalink != "" && (sameDowncase(permalink, prod.uniquePermalink.String) ||
		(prod.customPermalink.Valid && sameDowncase(permalink, prod.customPermalink.String)))
}

// sameDowncase is a.downcase == b.downcase. strings.EqualFold would also fold ſ to s, and
// strings.ToLower differs from downcase only on İ, which downcase makes "i̇".
func sameDowncase(a, b string) bool {
	return rails.Downcase(a) == rails.Downcase(b)
}

// productIDFlags reads skip_product_id_check and force_product_id_timestamp in one round trip.
// An unread skip flag leaves the check in place, and an unread cutoff falls back to this
// process's last successful read, nil included, which only a read that Rails makes updates.
func (h *handler) productIDFlags(ctx context.Context, productID int64, now time.Time) (skip bool, cutoff *time.Time, err error) {
	values, redisErr := h.redis.MGet(ctx, skipProductIDCheckPrefix+itoa(productID), forceProductIDTimestampKey).Result()
	h.mu.Lock()
	defer h.mu.Unlock()
	if redisErr != nil {
		return false, h.lastKnownForceProductTS, nil
	}
	if flag, _ := values[0].(string); rails.Present(flag) {
		return true, nil, nil
	}
	if value, _ := values[1].(string); rails.Present(value) {
		t, err := rails.DateTimeParse(value, now)
		if err != nil {
			return false, nil, fmt.Errorf("%s %q: %w", forceProductIDTimestampKey, value, err)
		}
		utc := t.UTC()
		cutoff = &utc
	}
	h.lastKnownForceProductTS = cutoff
	return false, cutoff, nil
}

// updateLicenseUses is increment!(:uses), whose License override schedules the reindex.
func (h *handler) updateLicenseUses(ctx context.Context, req *rails.Request, lic *license) error {
	if err := h.store.incrementUses(ctx, lic.id); err != nil {
		return err
	}
	lic.uses = sql.NullInt64{Int64: lic.uses.Int64 + 1, Valid: true}
	if lic.purchaseID.Valid {
		// Sidekiq Pro's reliable_push buffers through a Redis outage rather than failing the request.
		_, err := h.sidekiq.PushIn(ctx, sidekiq.Options{Class: "ElasticsearchIndexerWorker", Queue: "default", Retry: 10}, 2*time.Second,
			"update", sidekiq.Hash{{Key: "record_id", Value: lic.purchaseID.Int64}, {Key: "class_name", Value: "Purchase"}, {Key: "fields", Value: []any{"license_uses"}}})
		if err != nil {
			web.Logger(req.HTTP).Error("Could not schedule the license_uses reindex", "purchase_id", lic.purchaseID.Int64, "error", err.Error())
		}
	}
	return nil
}

// successWithLicense is the controller's success_with_license.
func (h *handler) successWithLicense(ctx context.Context, w http.ResponseWriter, req *rails.Request, lk *lookup) error {
	response := rails.NewRHash().Sym("success", true).Str("uses", nullInt(lk.license.uses))
	switch {
	case lk.purchase != nil:
		graph, err := loadPurchaseGraph(ctx, h.store, lk)
		if err != nil {
			return err
		}
		payload, err := buildPurchaseJSON(graph, h.cfg, h.ids)
		if err != nil {
			return err
		}
		response.Sym("purchase", payload)
	case lk.license.importedCustomerID.Valid:
		customer, err := h.store.importedCustomer(ctx, lk.license.importedCustomerID.Int64)
		if err != nil {
			return err
		}
		if customer != nil {
			payload, err := importedCustomerJSON(customer, h.ids, req.Now)
			if err != nil {
				return err
			}
			response.Sym("imported_customer", payload)
		}
	}
	rails.RenderJSON(w, req, http.StatusOK, rails.EncodeJSON(response))
	return nil
}

var cliUserAgent = regexp.MustCompile(`(?i)\Agumroad-cli/`)

// logMethodUse is Api::V2::BaseController#log_method_use, the after_action of every v2 action.
func (h *handler) logMethodUse(ctx context.Context, req *rails.Request, token *oauth.Token) {
	if token == nil {
		return
	}
	owner := token.Owner
	logger := web.Logger(req.HTTP)
	logger.Info("api v2 user:" + itoa(owner.ID) + " token:" + itoa(token.ID) + " in api/v2/licenses#verify")
	if ua := req.UserAgent(); ua == nil || !cliUserAgent.MatchString(*ua) || owner.Flags&userHasUsedCLI != 0 {
		return
	}
	if err := h.store.markCLIUser(ctx, owner.ID); err != nil {
		logger.Error("Failed to mark CLI user: "+err.Error(), errorreport.LogOnly)
	}
}
