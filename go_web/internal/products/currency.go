package products

import (
	"context"
	"database/sql"
	"errors"
	"math/big"
	"regexp"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// crossBorderCountries is Country::CROSS_BORDER_PAYOUTS_COUNTRIES, whose Stripe accounts
// can't take charges.
var crossBorderCountries = map[string]bool{}

func init() {
	for _, c := range []string{"TH", "KR", "IL", "TT", "PH", "MX", "AR", "PE", "AL", "BH", "AZ", "AO", "NE", "SM", "NG", "JO",
		"IN", "BA", "VN", "TW", "AG", "TZ", "NA", "ID", "CR", "CL", "BW", "PK", "TR", "MA", "RS", "ZA", "ET", "BN", "GY", "GT",
		"KE", "EG", "CO", "SA", "RW", "KZ", "EC", "MY", "UY", "MU", "JM", "OM", "BD", "BT", "LA", "MZ", "DO", "UZ", "BO", "TN",
		"MD", "MK", "PA", "SV", "MG", "PY", "GH", "AM", "LK", "KW", "IS", "QA", "BS", "LC", "SN", "KH", "MN", "GA", "MC", "DZ",
		"MO", "BJ", "CI", "GM"} {
		crossBorderCountries[c] = true
	}
}

// settlementMismatchTTL is MerchantAccount::SETTLEMENT_CURRENCY_MISMATCH_TTL.
const settlementMismatchTTL = 24 * time.Hour

var usdRate = rubyDecimal{big.NewRat(1, 1), 1}

// currencyDisplay is buyer_currency_display_props in buyer_local mode; nil is the default.
type currencyDisplay struct {
	buyer      string
	localCents int64
	rate       float64
}

// localCurrencyBuyer is the page's buyer currency when a local price may show: the seller has
// opted in, and the currency cookie or GeoIP names one.
func (h *handler) localCurrencyBuyer(p *page, v *view) (*string, error) {
	if raw, ok := v.sellerJSON.present("disable_buyer_local_currency"); ok {
		if disabled := rails.BooleanCast(raw); disabled != nil && *disabled {
			return nil, nil
		}
	}
	on, err := h.flag(p.Ctx, "buyer_local_currency", p.seller.id)
	if err != nil || !on {
		return nil, err
	}
	if buyer := buyerCurrencyPreference(p); buyer != nil {
		return buyer, nil
	}
	return v.detectedCurrency, nil
}

// currencyDisplayFor is the rest of buyer_currency_display_props for a product priced at price
// in pc, for the shapes this port serves, where unquotable products and the India mandate path
// never arise. Each step that ends in the default display has no side effect, so the cheap ones
// run first. Rails rescues every error into the default display; whether it would fail too is
// unknowable here, so errors go to Rails.
func (h *handler) currencyDisplayFor(p *page, buyer, pc string, price *int64) (*currencyDisplay, error) {
	if buyer == pc || price == nil {
		// A nil price raises in BigDecimal(""), and the rescue shows the default.
		return nil, nil
	}
	if _, ok := currencies[buyer]; !ok {
		return nil, fallback("buyer currency")
	}
	if _, ok := currencies[pc]; !ok {
		return nil, fallback("product currency")
	}
	from, ok, err := h.cachedUSDRate(p, pc)
	if err != nil || !ok {
		return nil, err
	}
	to, ok, err := h.cachedUSDRate(p, buyer)
	if err != nil || !ok {
		return nil, err
	}
	if p.settleable == nil {
		settleable, err := h.buyerCurrencySettleable(p, buyer)
		if err != nil {
			return nil, err
		}
		p.settleable = &settleable
	}
	if !*p.settleable {
		return nil, nil
	}
	rate := bigDecimalQuo(to, from)
	f, _ := rate.Float64()
	return &currencyDisplay{buyer: buyer, localCents: localPriceCents(*price, pc, buyer, rate), rate: f}, nil
}

// buyerCurrencySettleable is buyer_currency_settleable? past the checks this shape always
// passes; charge_minor_units_compatible? holds for every CURRENCY_CHOICES code.
func (h *handler) buyerCurrencySettleable(p *page, buyer string) (bool, error) {
	if buyer == "usd" {
		return true, nil
	}
	if on, err := h.flag(p.Ctx, "buyer_currency_charging", p.seller.id); err != nil || !on {
		return true, err
	}
	own, err := h.sellerHasStripeAccount(p.Ctx, p.seller.id)
	if err != nil {
		return false, err
	}
	if own {
		// supported_merchant_account? for a seller's own Custom account.
		if on, err := h.flag(p.Ctx, "buyer_currency_destination_charges", p.seller.id); err != nil || !on {
			return false, err
		}
	}
	// usd_settling_merchant_account? asks the platform account, which mints the quote.
	platform, err := h.platformStripeAccount(p.Ctx)
	if err != nil || platform == nil {
		return false, err
	}
	if c := platform.currency.String; c != "" && rails.Downcase(c) != "usd" {
		return false, fallback("platform settlement currency")
	}
	fresh, err := freshMismatch(platform.mismatches, buyer, p.Req.Now)
	if err != nil || !fresh {
		return !fresh, err
	}
	// eur_native_charging_shape? is the only way past a fresh marker.
	if on, err := h.flag(p.Ctx, "eur_native_charging", p.seller.id); err != nil || on {
		return false, firstErr(err, fallback("eur native charging"))
	}
	return false, nil
}

// iso8601 is Time#iso8601, which record_settlement_currency_mismatch! writes.
var iso8601 = regexp.MustCompile(`\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})\z`)

// freshMismatch is fresh_mismatch_timestamp? on the map's entry for currency. Anything but
// what Time#iso8601 writes goes to Rails, which reads it with Time.zone.parse.
func freshMismatch(mismatches *rails.Hash, currency string, now time.Time) (bool, error) {
	if mismatches == nil {
		return false, nil
	}
	raw := mismatches.Value(currency)
	if !rails.Present(raw) {
		return false, nil
	}
	s, ok := raw.(string)
	if !ok || !iso8601.MatchString(s) {
		return false, fallback("settlement currency mismatch")
	}
	at, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return false, fallback("settlement currency mismatch")
	}
	return at.After(now.Add(-settlementMismatchTTL)), nil
}

// sellerHasStripeAccount is whether User#merchant_account("stripe") is the seller's own: an
// alive, charge-processor-alive Stripe account whose country can take charges. A Connect
// account goes to Rails: merchant_migration_enabled? reads compliance info.
func (h *handler) sellerHasStripeAccount(ctx context.Context, sellerID int64) (bool, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT merchant_accounts.json_data, merchant_accounts.country FROM merchant_accounts"+
		" WHERE merchant_accounts.user_id = ? AND merchant_accounts.deleted_at IS NULL"+
		" AND merchant_accounts.charge_processor_alive_at IS NOT NULL AND merchant_accounts.charge_processor_deleted_at IS NULL"+
		" AND merchant_accounts.charge_processor_id = 'stripe'", sellerID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	own := false
	for rows.Next() {
		var raw, country sql.NullString
		if err := rows.Scan(&raw, &country); err != nil {
			return false, err
		}
		data, ok := parseJSONData(raw)
		if !ok {
			return false, fallback("merchant account json_data")
		}
		switch meta := data.get("meta").(type) {
		case nil:
		case *rails.Hash:
			if meta.Value("stripe_connect") == "true" {
				return false, fallback("stripe connect account")
			}
		default:
			return false, fallback("merchant account json_data")
		}
		own = own || !crossBorderCountries[country.String]
	}
	return own, rows.Err()
}

type platformAccount struct {
	currency   sql.NullString
	mismatches *rails.Hash
}

// platformStripeAccount is MerchantAccount.gumroad("stripe").
func (h *handler) platformStripeAccount(ctx context.Context) (*platformAccount, error) {
	var raw sql.NullString
	a := &platformAccount{}
	err := h.c.DB.QueryRowContext(ctx, "SELECT merchant_accounts.json_data, merchant_accounts.currency FROM merchant_accounts"+
		" WHERE merchant_accounts.user_id IS NULL AND merchant_accounts.charge_processor_id = 'stripe'"+
		" ORDER BY merchant_accounts.id ASC LIMIT 1").Scan(&raw, &a.currency)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	data, ok := parseJSONData(raw)
	if !ok {
		return nil, fallback("merchant account json_data")
	}
	switch m, _ := data.present("settlement_currency_mismatch_map"); m := m.(type) {
	case nil:
	case *rails.Hash:
		a.mismatches = m
	default:
		return nil, fallback("settlement currency mismatch")
	}
	return a, nil
}

// cachedUSDRate is cached_usd_rate: currencies:<CODE> as String#to_d, absent unless positive.
func (h *handler) cachedUSDRate(p *page, code string) (rubyDecimal, bool, error) {
	if code == "usd" {
		return usdRate, true, nil
	}
	raw, found, err := h.currencyRate(p, code)
	if err != nil || !found || rails.Blank(raw) {
		return rubyDecimal{}, false, err
	}
	d, ok := parseRubyDecimal(raw)
	if !ok {
		return rubyDecimal{}, false, fallback("currency rate")
	}
	if d.r.Sign() <= 0 {
		return rubyDecimal{}, false, nil
	}
	return d, true, nil
}

type rateRead struct {
	raw   string
	found bool
}

// currencyRate is $redis currencies:<CODE>, read once per page. Rails reads a failed get as
// no rate; whether it would fail too is unknowable here.
func (h *handler) currencyRate(p *page, code string) (string, bool, error) {
	upper, ok := asciiUpcase(code)
	if !ok {
		return "", false, fallback("currency code")
	}
	if r, ok := p.rates[upper]; ok {
		return r.raw, r.found, nil
	}
	raw, err := h.c.Page.Redis.Get(p.Ctx, "currencies:"+upper).Result()
	found := err == nil
	if err != nil && !errors.Is(err, redis.Nil) {
		return "", false, fallback("currency rate")
	}
	if p.rates == nil {
		p.rates = map[string]rateRead{}
	}
	p.rates[upper] = rateRead{raw, found}
	return raw, found, nil
}
