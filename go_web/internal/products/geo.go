package products

import (
	"context"
	"errors"
	"strings"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

type currency struct {
	minPrice   int64
	singleUnit bool
	// prefix and suffix are MoneyFormatter's symbol around the amount.
	prefix, suffix string
}

// currencyFor is get_currency_by_type: an unknown currency reads as USD's.
func currencyFor(code string) currency {
	if c, ok := currencies[strings.ToLower(code)]; ok {
		return c
	}
	return currencies["usd"]
}

// unitScalingFactor is CurrencyHelper#unit_scaling_factor.
func unitScalingFactor(code string) int64 {
	if currencyFor(code).singleUnit {
		return 1
	}
	return 100
}

// buyerCurrencyForCountry is CurrencyHelper#buyer_currency_for_country.
func buyerCurrencyForCountry(alpha2 *string) *string {
	if alpha2 == nil || rails.Blank(*alpha2) {
		return nil
	}
	code := strings.ToUpper(*alpha2)
	// BUYER_CURRENCY_COUNTRY_OVERRIDES: Bulgaria adopted the euro.
	cur := "eur"
	if code != "BG" {
		c, ok := countryCurrencies[code]
		if !ok {
			return nil
		}
		cur = strings.ToLower(c)
	}
	if _, ok := currencies[cur]; !ok {
		return nil
	}
	return &cur
}

// lookup is GeoIp.lookup, nil for an address it can't place.
func (h *handler) lookup(ip string) *geoip.Result {
	if h.c.Page.GeoIP == nil {
		return nil
	}
	return h.c.Page.GeoIP.Lookup(ip)
}

// complianceBlocked is Link#compliance_blocked(ip).
func complianceBlocked(geo *geoip.Result) bool {
	if geo == nil {
		return false
	}
	alpha2 := deref(geo.CountryCode)
	switch alpha2 {
	case "CU", "IR", "KP":
		return true
	}
	region := deref(geo.RegionName)
	if alpha2 == "" || rails.Blank(region) {
		return false
	}
	var codes []string
	switch strings.ToUpper(alpha2) {
	case "UA":
		codes = []string{"43", "40", "14", "09"}
	case "RU":
		codes = []string{"CR", "SEV"}
	}
	sub := strings.TrimPrefix(strings.ToUpper(region), strings.ToUpper(alpha2)+"-")
	for _, c := range codes {
		if c == sub {
			return true
		}
	}
	return false
}

// pppFactor is PurchasingPowerParityService#get_factor without the seller's floor: the
// ppp namespace's stored factor for the country, 1 when there is none. ok is false when
// Redis fails, where Rails falls back to the floor alone.
func pppFactor(ctx context.Context, r redis.Cmdable, country *string) (factor float64, ok bool) {
	if country == nil || rails.Blank(*country) {
		return 1, true
	}
	v, err := r.Get(ctx, "ppp:"+*country).Result()
	if errors.Is(err, redis.Nil) || rails.Blank(v) {
		return 1, true
	}
	if err != nil {
		return 0, false
	}
	f, exact := rails.StringToF(v)
	return f, exact
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
