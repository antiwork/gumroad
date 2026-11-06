package products

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// testdata/usd_cents.json.gz is get_usd_cents on bigdecimal 3.3.1, with the rate read as
// cached_rate reads it: String#to_f, then Float#to_s#to_f. USD_CENTS_FILE runs a larger set.
func TestUSDCentsMatchesRuby(t *testing.T) {
	path := "testdata/usd_cents.json.gz"
	if p := os.Getenv("USD_CENTS_FILE"); p != "" {
		path = p
	}
	data, err := testfiles.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Rate                 string
		Cents, Multi, Single int64
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, c := range cases {
		// The page falls back on a rate StringToF can't read exactly.
		rate, exact := rails.StringToF(c.Rate)
		if !exact {
			continue
		}
		checked++
		for _, x := range []struct {
			single bool
			want   int64
		}{{false, c.Multi}, {true, c.Single}} {
			got, ok := usdCents(c.Cents, rate, x.single)
			if ok && got != x.want || !ok && x.want <= maxUSDCents {
				t.Errorf("%d / %s (single unit %v): %d %v, want %d", c.Cents, c.Rate, x.single, got, ok, x.want)
			}
		}
	}
	if checked < len(cases)*9/10 {
		t.Errorf("only %d of %d rates read exactly", checked, len(cases))
	}
	t.Logf("%d of %d cases", checked, len(cases))
}

// BigDecimal cuts a 17-digit Float to 16 digits; rounding it instead gets 62.
func TestUSDCentsCutsTheRateTo16Digits(t *testing.T) {
	if got, ok := usdCents(1, 0.016000000000000004, false); !ok || got != 63 {
		t.Errorf("%d %v, want 63", got, ok)
	}
}
