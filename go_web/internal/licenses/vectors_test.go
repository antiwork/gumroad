package licenses

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// testdata/vectors.rb writes these from the real gems (actionpack 8.1.3.1, rack 3.2.6,
// rack-utf8_sanitizer 1.9.1, actionview 8.1.3.1, json 2.13.2) under Ruby 3.4.

func loadVectors(t *testing.T, name string, into any) {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, into); err != nil {
		t.Fatal(err)
	}
}

func canonParam(v any) any {
	switch v := v.(type) {
	case string:
		return "s:" + v
	case json.Number:
		return "n:" + string(v)
	case rails.File:
		return "file"
	case []any:
		out := []any{}
		for _, element := range v {
			out = append(out, canonParam(element))
		}
		return out
	case *rails.Hash:
		out := map[string]any{}
		for _, k := range v.Keys() {
			out[k] = canonParam(v.Value(k))
		}
		return out
	}
	return v
}

// The body, query and sanitizer cases this action meets, run through the shared stack.
func TestParamsMatchActionDispatch(t *testing.T) {
	var cases []struct {
		Query       string  `json:"query"`
		Body        string  `json:"body"`
		ContentType *string `json:"content_type"`
		Format      string  `json:"format"`
		Want        any     `json:"want"`
	}
	loadVectors(t, "params.json", &cases)
	stack := newHarness(t, nil, nil).handler.stack
	for i, c := range cases {
		query, _ := hex.DecodeString(c.Query)
		body, _ := hex.DecodeString(c.Body)
		r := httptest.NewRequest("POST", "/v2/licenses/verify", bytes.NewReader(body))
		r.RequestURI = "/v2/licenses/verify?" + string(query)
		r.URL.RawQuery = string(query)
		if c.ContentType != nil {
			r.Header["Content-Type"] = []string{*c.ContentType}
		}
		pathParams := [][2]string{{"controller", "api/v2/licenses"}, {"action", "verify"}}
		if c.Format != "" {
			pathParams = append(pathParams, [2]string{"format", c.Format})
		}

		var got any
		req, err := stack.Parse(r, pathParams, testNow)
		switch {
		case errors.Is(err, rails.ErrNotAcceptable):
			got = "error:invalid_mime"
		case errors.Is(err, rails.ErrBadRequest):
			got = "error:bad_request"
		case errors.Is(err, rails.ErrParse):
			got = "error:json_parse"
		case err != nil:
			got = "error:" + err.Error()
		default:
			got = canonParam(req.Params)
		}
		if !reflect.DeepEqual(got, c.Want) {
			t.Errorf("case %d (query %q, body %.60q, type %v): got %v, want %v", i, query, body, c.ContentType, got, c.Want)
		}
	}
}

func TestTimeAgoInWordsMatchesActionView(t *testing.T) {
	var cases []struct{ From, Now, Want string }
	loadVectors(t, "time_ago.json", &cases)
	for _, c := range cases {
		from, _ := time.Parse(time.RFC3339, c.From)
		now, _ := time.Parse(time.RFC3339, c.Now)
		if got := timeAgoInWords(from, now); got != c.Want {
			t.Errorf("timeAgoInWords(%s, %s) = %q, want %q", c.From, c.Now, got, c.Want)
		}
	}
}

// From Money.new(cents, currency).format(no_cents_if_whole: true, symbol: true) under
// config/initializers/money.rb.
var moneyVectors = map[string][]string{
	"usd": {"$0", "$0.01", "$0.05", "$0.50", "$0.99", "$1", "$1.50", "$12.34", "$1,000", "$1,234,567.89", "$-2.50"},
	"jpy": {"¥0", "¥1", "¥5", "¥50", "¥99", "¥100", "¥150", "¥1,234", "¥100,000", "¥123,456,789", "¥-250"},
	"chf": {"CHF 0", "CHF 0.01", "CHF 0.05", "CHF 0.50", "CHF 0.99", "CHF 1", "CHF 1.50", "CHF 12.34", "CHF 1,000", "CHF 1,234,567.89", "CHF -2.50"},
	"pln": {"0 zł", "0.01 zł", "0.05 zł", "0.50 zł", "0.99 zł", "1 zł", "1.50 zł", "12.34 zł", "1,000 zł", "1,234,567.89 zł", "-2.50 zł"},
	"krw": {"₩0", "₩0.01", "₩0.05", "₩0.50", "₩0.99", "₩1", "₩1.50", "₩12.34", "₩1,000", "₩1,234,567.89", "₩-2.50"},
	"vnd": {"0 ₫", "1 ₫", "5 ₫", "50 ₫", "99 ₫", "100 ₫", "150 ₫", "1,234 ₫", "100,000 ₫", "123,456,789 ₫", "-250 ₫"},
	"dkk": {"0 kr.", "0.01 kr.", "0.05 kr.", "0.50 kr.", "0.99 kr.", "1 kr.", "1.50 kr.", "12.34 kr.", "1,000 kr.", "1,234,567.89 kr.", "-2.50 kr."},
	"sar": {"ر.س0", "ر.س0.01", "ر.س0.05", "ر.س0.50", "ر.س0.99", "ر.س1", "ر.س1.50", "ر.س12.34", "ر.س1,000", "ر.س1,234,567.89", "ر.س-2.50"},
}

func TestFormatMoneyMatchesTheMoneyGem(t *testing.T) {
	amounts := []int64{0, 1, 5, 50, 99, 100, 150, 1234, 100000, 123456789, -250}
	for currency, want := range moneyVectors {
		for i, cents := range amounts {
			if got, err := formatMoney(cents, strings.ToUpper(currency)); err != nil || got != want[i] {
				t.Errorf("formatMoney(%d, %s) = %q, %v; want %q", cents, currency, got, err, want[i])
			}
		}
	}
	if len(currencyFormats) != 32 {
		t.Errorf("config/currencies.json lists 32 currencies, the table has %d", len(currencyFormats))
	}
	if _, err := formatMoney(1, "xyz"); err == nil {
		t.Error("an unknown currency must fail like Money::Currency::UnknownCurrency")
	}
}
