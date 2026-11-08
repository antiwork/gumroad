package products

import (
	"context"
	"database/sql"
	"errors"
	"math/big"
	"regexp"
	"slices"
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
	// originalLocalCents is buyer_local_original_price_cents, set when a discount shows.
	originalLocalCents *int64
}

// setOriginal sets buyer_local_original_price_cents for original, in productCurrency.
func (c *currencyDisplay) setOriginal(original int64, productCurrency string) {
	// buyer_local_price_props converts the original through the shown Float rate.
	local := localPriceCents(original, productCurrency, c.buyer, shortestRat(c.rate))
	c.originalLocalCents = &local
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

// currencyDisplayFor is the rest of buyer_currency_display_props for prod at price; hasPlan is
// whether it has an alive installment plan. Each step that ends in the default display has no
// side effect, so the cheap ones run first. Rails rescues every error into the default display;
// whether it would fail too is unknowable here, so errors go to Rails.
func (h *handler) currencyDisplayFor(p *page, prod *product, hasPlan bool, buyer string, price *int64) (*currencyDisplay, error) {
	pc := prod.productCurrency()
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
	if settleable, err := h.buyerCurrencySettleable(p, prod, hasPlan, buyer); err != nil || !settleable {
		return nil, err
	}
	rate := bigDecimalQuo(to, from)
	f, _ := rate.Float64()
	return &currencyDisplay{buyer: buyer, localCents: localPriceCents(*price, pc, buyer, rate), rate: f}, nil
}

// buyerCurrencySettleable is buyer_currency_settleable? past the checks this shape always
// passes; charge_minor_units_compatible? holds for every CURRENCY_CHOICES code.
func (h *handler) buyerCurrencySettleable(p *page, prod *product, hasPlan bool, buyer string) (bool, error) {
	if buyer == "usd" {
		return true, nil
	}
	if on, err := h.pageFlag(p, "buyer_currency_charging"); err != nil || !on {
		return true, err
	}
	if unquotable, err := h.unquotableProduct(p, prod, hasPlan); err != nil || unquotable {
		return false, err
	}
	if p.settleable == nil {
		account, err := h.sellerStripeAccount(p)
		if err != nil {
			return false, err
		}
		settles, err := h.accountSettles(p, account, buyer)
		if err != nil {
			return false, err
		}
		p.settleable = &settleability{settles: settles, direct: account != nil && account.connect}
	}
	s := p.settleable
	if !s.settles || s.direct || !prod.is(productIsRecurringBilling) {
		return s.settles, nil
	}
	// indian_card_mandate_presentment_supported? comes before the settlement checks in Rails, so
	// asking it after them can only add a fallback.
	on, err := h.pageFlag(p, "india_card_mandate_reliability")
	return !on || slices.Contains(indianCardMandateCurrencies, buyer), err
}

// settleability is accountSettles for the page's seller and buyer currency.
type settleability struct {
	settles bool
	// direct is direct_charge_account?, whose charges the India mandate doesn't constrain.
	direct bool
}

// unquotableProduct is buyer_currency_unquotable_product?. Past localCurrencyBuyer and the
// charging flag, subscriptions_enabled? is its own flag alone.
func (h *handler) unquotableProduct(p *page, prod *product, hasPlan bool) (bool, error) {
	if prod.is(productFreeTrialEnabled) {
		return true, nil
	}
	if prod.is(productIsInPreorderState) || prod.nativeType == "commission" || hasPlan || prod.is(productIsRecurringBilling) {
		on, err := h.pageFlag(p, "buyer_currency_subscriptions")
		return !on, err
	}
	return false, nil
}

// indianCardMandateCurrencies is StripeChargeProcessor::INDIA_CARD_MANDATE_CURRENCIES.
var indianCardMandateCurrencies = []string{"inr", "aud", "usd", "eur", "gbp", "sgd", "cad", "chf", "sek", "aed", "jpy", "nok", "myr", "hkd"}

// accountSettles is the rest of buyer_currency_settleable? for the seller's account, from
// supported_merchant_account? on.
func (h *handler) accountSettles(p *page, account *stripeAccount, buyer string) (bool, error) {
	if account != nil && account.connect {
		// A Connect account is supported and mints its own quote, so it must hold USD and carry no
		// fresh marker: eur_native_charging_shape? needs the platform account.
		if c := account.currency.String; !rails.Blank(c) && rails.Downcase(c) != "usd" {
			return false, nil
		}
		mismatches, err := mismatchMap(account.data)
		if err != nil {
			return false, err
		}
		if fresh, err := freshMismatch(mismatches, buyer, p.Req.Now); err != nil || fresh {
			return false, err
		}
		// The pre-map blanket marker counts on a seller's own account.
		noticed, _ := account.data.present("settlement_currency_mismatch_noticed_at")
		fresh, err := freshTimestamp(noticed, p.Req.Now)
		return !fresh, err
	}
	if account != nil {
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
	if c := platform.currency.String; !rails.Blank(c) && rails.Downcase(c) != "usd" {
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

// freshMismatch is fresh_mismatch_timestamp? on the map's entry for currency.
func freshMismatch(mismatches *rails.Hash, currency string, now time.Time) (bool, error) {
	if mismatches == nil {
		return false, nil
	}
	return freshTimestamp(mismatches.Value(currency), now)
}

// freshTimestamp is fresh_mismatch_timestamp? for one marker. Anything but what Time#iso8601
// writes goes to Rails, which reads it with Time.zone.parse.
func freshTimestamp(raw any, now time.Time) (bool, error) {
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

// stripeAccount is the seller's own Stripe account that User#merchant_account("stripe") picks.
type stripeAccount struct {
	connect  bool
	currency sql.NullString
	data     jsonData
}

// sellerStripeAccount is User#merchant_account("stripe") among the seller's alive,
// charge-processor-alive Stripe accounts: the first Connect one when merchant_migration_enabled?,
// else the first other one whose country can take charges; nil is MerchantAccount.gumroad.
func (h *handler) sellerStripeAccount(p *page) (*stripeAccount, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT merchant_accounts.json_data, merchant_accounts.country, merchant_accounts.currency"+
		" FROM merchant_accounts WHERE merchant_accounts.user_id = ? AND merchant_accounts.deleted_at IS NULL"+
		" AND merchant_accounts.charge_processor_alive_at IS NOT NULL AND merchant_accounts.charge_processor_deleted_at IS NULL"+
		" AND merchant_accounts.charge_processor_id = 'stripe' ORDER BY merchant_accounts.id", p.seller.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var connect, own *stripeAccount
	for rows.Next() {
		var raw, country sql.NullString
		a := &stripeAccount{}
		if err := rows.Scan(&raw, &country, &a.currency); err != nil {
			return nil, err
		}
		if a.data, a.connect, err = merchantAccountConnect(raw); err != nil {
			return nil, err
		}
		switch {
		case a.connect && connect == nil:
			connect = a
		case !a.connect && own == nil && !crossBorderCountries[country.String]:
			own = a
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if connect != nil {
		if p.seller.is(userCheckMerchantAccountIsLinked) {
			return connect, nil
		}
		routes, err := h.stripeConnectRoutes(p)
		if err != nil || routes {
			return connect, err
		}
	}
	return own, nil
}

// stripeConnectCountries is StripeMerchantAccountManager::COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT.
var stripeConnectCountries = map[string]bool{"AU": true, "AT": true, "BE": true, "BR": true, "BG": true, "CA": true, "HR": true,
	"CY": true, "CZ": true, "DK": true, "EE": true, "FI": true, "FR": true, "DE": true, "GI": true, "GR": true, "HK": true, "HU": true,
	"IE": true, "IT": true, "JP": true, "LV": true, "LI": true, "LT": true, "LU": true, "MT": true, "NL": true, "NZ": true, "NO": true,
	"PL": true, "PT": true, "RO": true, "SG": true, "SK": true, "SI": true, "ES": true, "SE": true, "CH": true, "AE": true, "GB": true,
	"US": true}

// stripeConnectRoutes is merchant_migration_enabled? without the linked flag: the feature, then
// stripe_connect_routing_country_code among the countries Stripe Connect supports.
func (h *handler) stripeConnectRoutes(p *page) (bool, error) {
	if on, err := h.flag(p.Ctx, "merchant_migration", p.seller.id); err != nil || !on {
		return false, err
	}
	info, err := h.complianceInfo(p.Ctx, p.seller.id)
	if err != nil || info == nil {
		return false, err
	}
	byEntity, err := h.flag(p.Ctx, "stripe_connect_routing_by_legal_entity_country", p.seller.id)
	if err != nil {
		return false, err
	}
	var code string
	if byEntity {
		code, err = info.legalEntityCountryCode()
	} else {
		code, err = complianceCountry(info.country)
	}
	return stripeConnectCountries[code], err
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
	if a.mismatches, err = mismatchMap(data); err != nil {
		return nil, err
	}
	return a, nil
}

// merchantAccountConnect reads a merchant account's json_data as Rails classifies it, by
// meta.stripe_connect; a json_data or meta Rails would raise on goes to Rails.
func merchantAccountConnect(raw sql.NullString) (jsonData, bool, error) {
	j, ok := parseJSONData(raw)
	if !ok {
		return jsonData{}, false, fallback("merchant account json_data")
	}
	switch meta := j.get("meta").(type) {
	case nil:
		return j, false, nil
	case *rails.Hash:
		return j, meta.Value("stripe_connect") == "true", nil
	}
	return jsonData{}, false, fallback("merchant account json_data")
}

// mismatchMap is settlement_currency_mismatch_map, nil when blank; anything else but a Hash
// goes to Rails.
func mismatchMap(data jsonData) (*rails.Hash, error) {
	m, present := data.present("settlement_currency_mismatch_map")
	if !present {
		return nil, nil
	}
	if h, ok := m.(*rails.Hash); ok {
		return h, nil
	}
	return nil, fallback("settlement currency mismatch")
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
