package products

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// testdata/local_price.json.gz is buyer_local_currency_rate, buyer_local_price_cents and
// buyer_local_price_props' rate on bigdecimal 3.3.1. LOCAL_PRICE_FILE runs a larger set.
func TestLocalPriceMatchesBigDecimal(t *testing.T) {
	path := "testdata/local_price.json.gz"
	if p := os.Getenv("LOCAL_PRICE_FILE"); p != "" {
		path = p
	}
	data, err := testfiles.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		From, To           string
		FromRate           *string `json:"from_rate"`
		ToRateJSON         *string `json:"to_rate"`
		Price, Local       int64
		Cross, Rate, Minor string
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	rate := func(s *string) rubyDecimal {
		if s == nil {
			return usdRate
		}
		d, ok := parseRubyDecimal(*s)
		if !ok {
			t.Fatalf("rate %q", *s)
		}
		return d
	}
	for _, c := range cases {
		cross := bigDecimalQuo(rate(c.ToRateJSON), rate(c.FromRate))
		want, ok := parseRubyDecimal(c.Cross)
		if !ok || cross.Cmp(want.r) != 0 {
			t.Errorf("%s->%s %v/%v: cross %s, want %s", c.From, c.To, c.ToRateJSON, c.FromRate, cross.FloatString(40), c.Cross)
			continue
		}
		local := localPriceCents(c.Price, c.From, c.To, cross)
		rf, _ := cross.Float64()
		minor := minorUnitRate(rf, c.From, c.To)
		wantRate, _ := strconv.ParseFloat(c.Rate, 64)
		wantMinor, _ := strconv.ParseFloat(c.Minor, 64)
		if local != c.Local || rf != wantRate || minor != wantMinor {
			t.Errorf("%s->%s %d: %d %v %v, want %d %s %s", c.From, c.To, c.Price, local, rf, minor, c.Local, c.Rate, c.Minor)
		}
	}
	t.Logf("%d cases", len(cases))
}
