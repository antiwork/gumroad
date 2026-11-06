package products

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/customstyles"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// User::ReputationSummary's constants.
const (
	reputationMinReviews  = 10
	reputationMinProducts = 2
	reputationCacheTTL    = 10 * time.Minute
)

func flipperID(userID int64) string { return "User;" + strconv.FormatInt(userID, 10) }

// flag is Feature.active?(name, seller); a flag only Flipper can evaluate goes to Rails.
func (h *handler) flag(ctx context.Context, name string, userID int64) (bool, error) {
	on, err := h.c.Page.Flag(name).ActiveFor(ctx, flipperID(userID))
	if errors.Is(err, flipper.ErrUnevaluable) {
		return false, fallback("flag " + name)
	}
	return on, err
}

// loadReputation is seller_reputation_summary twice: the product props' snapshot, less the
// product's own reviews, and the creator profile's cached aggregate.
func (h *handler) loadReputation(ctx context.Context, p *page, prod *product, v *view) error {
	seller := p.seller
	on, err := h.flag(ctx, "seller_reputation_summary", seller.id)
	if err != nil || !on {
		return err
	}
	v.reputationEnabled = true
	r := h.c.Page.Redis
	id := strconv.FormatInt(seller.id, 10)
	versionKey := "seller_reputation_summary/version/" + id
	vals, err := r.MGet(ctx, "seller_reputation_summary/v2/snapshot/"+id, versionKey).Result()
	if err != nil {
		// Rails rescues and renders nil, after notifying.
		return fallback("reputation snapshot")
	}
	version := rubyToI(vals[1])
	var snapshot struct {
		Aggregate  []json.Number `json:"aggregate"`
		Signature  json.Number   `json:"signature"`
		ComputedAt json.Number   `json:"computed_at"`
	}
	raw, _ := vals[0].(string)
	current := false
	if raw != "" {
		d := json.NewDecoder(strings.NewReader(raw))
		d.UseNumber()
		if d.Decode(&snapshot) != nil {
			return fallback("reputation snapshot")
		}
		sig, sigOK := jsonInt(snapshot.Signature)
		current = sigOK && sig == version
	}
	computedAt, _ := jsonInt(snapshot.ComputedAt)
	if !current || computedAt <= p.Req.Now.Add(-reputationCacheTTL).Unix() {
		// WarmSellerReputationSummaryJob is enqueued.
		return fallback("reputation snapshot refresh")
	}
	agg, ok := aggregateOf(snapshot.Aggregate)
	if !ok {
		return fallback("reputation snapshot")
	}
	v.snapshotReputation = buildSummary(subtractProduct(agg, prod, v.reviewStat))

	// The profile's: Rails.cache.fetch keyed by the products' lifecycle and the version.
	lifecycle, err := h.productsCacheKey(p)
	if err != nil {
		return err
	}
	key := "seller_reputation_summary/v2/" + id + "/" + lifecycle + "/" + strconv.FormatInt(version, 10)
	cached, found, err := h.readCache(ctx, key)
	switch {
	case err != nil:
		return err
	case found:
		list, ok := cached.([]any)
		if !ok || len(list) != 3 {
			return fallback("cached reputation")
		}
		var a [3]int64
		for i, x := range list {
			if a[i], ok = x.(int64); !ok {
				return fallback("cached reputation")
			}
		}
		v.profileReputation = buildSummary(a)
		return nil
	}
	a, err := h.reputationAggregate(ctx, seller.id)
	if err != nil {
		return err
	}
	p.cacheWrites = append(p.cacheWrites, pendingWrite{key, []any{a[0], a[1], a[2]}, reputationCacheTTL})
	v.profileReputation = buildSummary(a)
	return nil
}

// reputationAggregate is reputation_aggregate's SQL.
func (h *handler) reputationAggregate(ctx context.Context, sellerID int64) ([3]int64, error) {
	var count, total, weighted sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, "SELECT COUNT(*), SUM(reviews_count), SUM(ratings_of_five_count * 5 + ratings_of_four_count * 4"+
		" + ratings_of_three_count * 3 + ratings_of_two_count * 2 + ratings_of_one_count) FROM `links` FORCE INDEX (index_links_on_user_id)"+
		" STRAIGHT_JOIN product_review_stats ON product_review_stats.link_id = links.id WHERE `links`.`purchase_disabled_at` IS NULL"+
		" AND `links`.`banned_at` IS NULL AND `links`.`deleted_at` IS NULL AND `links`.`draft` = FALSE AND `links`.`user_id` = ?"+
		" AND (links.flags & ? != 0) AND `product_review_stats`.`reviews_count` != 0 LIMIT 1", sellerID, productDisplayReviews).
		Scan(&count, &total, &weighted)
	return [3]int64{count.Int64, total.Int64, weighted.Int64}, err
}

// productsCacheKey is seller.products.cache_key_with_version, read once per page.
func (h *handler) productsCacheKey(p *page) (string, error) {
	if p.productsKey == "" {
		key, err := h.readProductsCacheKey(p.Ctx, p.seller.id)
		if err != nil {
			return "", err
		}
		p.productsKey = key
	}
	return p.productsKey, nil
}

func (h *handler) readProductsCacheKey(ctx context.Context, sellerID int64) (string, error) {
	sql := "SELECT `links`.* FROM `links` WHERE `links`.`user_id` = " + strconv.FormatInt(sellerID, 10)
	sum := sha256.Sum256([]byte(sql))
	key := "links/query-" + hex.EncodeToString(sum[:])[:32]
	var size int64
	var latest db.NullTime
	if err := h.c.DB.QueryRowContext(ctx, "SELECT COUNT(*), MAX(`links`.`updated_at`) FROM `links` WHERE `links`.`user_id` = ?", sellerID).
		Scan(&size, &latest); err != nil {
		return "", err
	}
	version := strconv.FormatInt(size, 10)
	if latest.Valid {
		// to_fs(:usec): %Y%m%d%H%M%S%6N.
		t := latest.Time.UTC()
		version += "-" + t.Format("20060102150405") + fmt.Sprintf("%06d", t.Nanosecond()/1000)
	}
	return key + "-" + version, nil
}

// subtractProduct is subtract_product: the product's own reviews out of the aggregate, when
// it counted in it.
func subtractProduct(agg [3]int64, prod *product, stat *reviewStat) [3]int64 {
	if stat == nil || stat.reviewsCount == 0 || !prod.is(productDisplayReviews) || !prod.alive() || prod.draft.Bool {
		return agg
	}
	weighted := int64(0)
	for i, c := range stat.counts {
		weighted += int64(i+1) * c
	}
	return [3]int64{agg[0] - 1, agg[1] - stat.reviewsCount, agg[2] - weighted}
}

// buildSummary is build_summary.
func buildSummary(agg [3]int64) any {
	products, total, weighted := agg[0], agg[1], agg[2]
	if total < reputationMinReviews || products < reputationMinProducts {
		return nil
	}
	return rails.NewRHash().
		Sym("average", rails.RoundFloat(float64(weighted)/float64(total), 1)).
		Sym("count", total).
		Sym("products_count", products)
}

func aggregateOf(nums []json.Number) ([3]int64, bool) {
	var a [3]int64
	if len(nums) != 3 {
		return a, false
	}
	for i, n := range nums {
		v, ok := jsonInt(n)
		if !ok {
			return a, false
		}
		a[i] = v
	}
	return a, true
}

func jsonInt(n json.Number) (int64, bool) {
	v, err := n.Int64()
	return v, err == nil
}

// rubyToI is a Redis GET's nil-or-String.to_i.
func rubyToI(v any) int64 {
	s, _ := v.(string)
	n, _ := rails.StringToI(s)
	return n
}

// recaptchaRequired is FollowRecaptcha.required?: a compliant, active seller never needs it.
func recaptchaRequired(seller *user, siteKey string) bool {
	if seller.riskState.String == "compliant" && !seller.deletedAt.Valid {
		return false
	}
	return rails.Present(siteKey)
}

// loadCustomStyles is SellerProfile#custom_styles, compiled here rather than read from
// Rails.cache, whose namespace is Rails' own deploy's, and whether the font preload is set.
func (h *handler) loadCustomStyles(ctx context.Context, p *page, v *view) error {
	var hl, bg, font, radius, hover sql.NullString
	err := h.c.DB.QueryRowContext(ctx, "SELECT highlight_color, background_color, font, border_radius, button_hover FROM seller_profiles"+
		" WHERE seller_id = ? LIMIT 1", p.seller.id).Scan(&hl, &bg, &font, &radius, &hover)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	ptr := func(s sql.NullString) *string {
		if !s.Valid {
			return nil
		}
		return &s.String
	}
	profile := customstyles.Profile{HighlightColor: ptr(hl), BackgroundColor: ptr(bg), Font: ptr(font), BorderRadius: ptr(radius), ButtonHover: ptr(hover)}
	// after_initialize's default font.
	v.fontPreload = !font.Valid || font.String == "ABC Favorit"
	css, err := customstyles.CSS(profile)
	if errors.Is(err, customstyles.ErrUnported) {
		return fallback("custom styles")
	}
	v.customStyles = css
	return err
}
