package rails

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func loadFixture(t *testing.T, name string, v any) {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

// Inputs Ruby parses but go_web declines; record_media_location then answers
// {success: false} instead of storing a time.
var unsupportedTimeInputs = map[string]bool{
	"1441819610": true,
	"2015-09-09T17:26:50 America/Los_Angeles":   true,
	"2015-09-09T17:26:50 Pacific Standard Time": true,
	"2015-09-09T17:26:50+5.5":                   true,
	"Wednesday, 09-Sep-15 17:26:50 GMT":         true,
}

func TestZoneParseMatchesTimeZoneParse(t *testing.T) {
	var cases []struct {
		Input string
		Time  string
		Nil   bool
		Error string
	}
	loadFixture(t, "time_parse.json", &cases)
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	for _, c := range cases {
		got, err := ZoneParse(c.Input, now)
		if err == ErrUnsupportedTime {
			if !unsupportedTimeInputs[c.Input] {
				t.Errorf("%q: declined, Ruby gave %+v", c.Input, c)
			}
			continue
		}
		if unsupportedTimeInputs[c.Input] {
			t.Errorf("%q: expected go_web to decline it, got %v %v", c.Input, got, err)
			continue
		}
		switch {
		case c.Error != "":
			if _, ok := err.(TimeArgumentError); !ok {
				t.Errorf("%q: Ruby raised %q, got %v %v", c.Input, c.Error, got, err)
			}
		case c.Nil:
			if got != nil || err != nil {
				t.Errorf("%q: Ruby returned nil, got %v %v", c.Input, got, err)
			}
		default:
			want, _ := time.Parse(time.RFC3339Nano, c.Time)
			if err != nil || got == nil || !got.Equal(want) {
				t.Errorf("%q: got %v %v, want %v", c.Input, got, err, want)
			}
		}
	}
}

func TestSanitizerMatchesRackUTF8Sanitizer(t *testing.T) {
	var cases []struct {
		Header bool
		Input  []byte
		Output []byte
	}
	loadFixture(t, "utf8_sanitizer.json", &cases)
	for _, c := range cases {
		got := sanitizeURIEncoded(string(c.Input))
		if c.Header {
			got = sanitizeString(string(c.Input))
		}
		if got != string(c.Output) {
			t.Errorf("%q: got %q, want %q", c.Input, got, c.Output)
		}
	}
}

func TestCookiesParseLikeRack(t *testing.T) {
	var cases []struct {
		Input     string
		Sanitized string
		Cookies   map[string]*string
	}
	loadFixture(t, "rack_cookies.json", &cases)
	for _, c := range cases {
		if got := parseCookies([]string{c.Input}); !reflect.DeepEqual(got, c.Cookies) {
			t.Errorf("%q parsed to %v, want %v", c.Input, got, c.Cookies)
		}
	}
}

// plain turns params into what JSON decoding of the Ruby fixture yields.
func plain(v any) any {
	switch v := v.(type) {
	case *Hash:
		out := map[string]any{}
		for _, k := range v.keys {
			out[k] = plain(v.values[k])
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = plain(item)
		}
		return out
	}
	return v
}

func TestQueryParamsMatchParamBuilder(t *testing.T) {
	var cases []struct {
		Input  string
		Params map[string]any
		Error  string
	}
	loadFixture(t, "rails_query.json", &cases)
	for _, c := range cases {
		pairs, err := queryPairs(c.Input)
		var params *Hash
		if err == nil {
			params, err = fromPairs(pairs, railsParamDepthLimit)
		}
		if c.Error != "" {
			if err == nil {
				t.Errorf("%q: Rails raised %s, got %v", c.Input, c.Error, plain(params))
			}
			continue
		}
		if err != nil || !reflect.DeepEqual(plain(params), c.Params) {
			t.Errorf("%q: got %v %v, want %v", c.Input, plain(params), err, c.Params)
		}
	}
}

func TestJSONParamsMatchActionDispatch(t *testing.T) {
	var cases []struct {
		Input   []byte
		Inspect string
		Error   string
	}
	loadFixture(t, "json_params.json", &cases)
	for _, c := range cases {
		params, err := jsonParams(c.Input)
		switch {
		case c.Error == "ParseError" && err != ErrParse, c.Error == "BadRequest" && err != ErrBadRequest:
			t.Errorf("%.40q: got %v, Rails %s", c.Input, err, c.Error)
		case c.Error == "" && (err != nil || rubyInspect(params) != c.Inspect):
			got := ""
			if err == nil {
				got = rubyInspect(params)
			}
			t.Errorf("%.40q:\n got %.120s %v\nwant %.120s", c.Input, got, err, c.Inspect)
		}
	}
	// A deep body no longer recurses without bound.
	if _, err := jsonParams([]byte(strings.Repeat("[", 1_000_000))); err != ErrParse {
		t.Errorf("deep body: %v", err)
	}
}

func TestJSONParamsKeepOrderAndDropNils(t *testing.T) {
	params, err := jsonParams([]byte(`{"b":1,"a":[null,"x",{"c":null}],"n":12.50}`))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(params.keys, []string{"b", "a", "n"}) {
		t.Fatalf("keys = %v", params.keys)
	}
	if got := rubyInspect(params); got != `{"b" => 1, "a" => ["x", {"c" => nil}], "n" => 12.5}` {
		t.Fatalf("inspect = %s", got)
	}
	if wrapped, _ := jsonParams([]byte(`[1,2]`)); !reflect.DeepEqual(plain(wrapped.values["_json"]), []any{json.Number("1"), json.Number("2")}) {
		t.Fatal("a top-level array is wrapped as _json")
	}
	for _, bad := range []string{`{`, `{"a":1} {}`, `  `} {
		if _, err := jsonParams([]byte(bad)); err != ErrParse {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

func TestCookieLineMatchesRackAndSecureHeaders(t *testing.T) {
	var fixture struct {
		SecureHeaders string `json:"secure_headers"`
	}
	loadFixture(t, "guid_cookie.json", &fixture)
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	if got := CookieLine("_gumroad_guid", "11111111-2222-4333-8444-555555555555", CookieDomainAll("seller.gumroad.com"), "", AddYears(now, 10), true, true); got != fixture.SecureHeaders {
		t.Fatalf("got  %s\nwant %s", got, fixture.SecureHeaders)
	}
	for host, want := range map[string]string{"gumroad.com": "gumroad.com", "a.b.example.co.uk": "example.co.uk", "localhost": "", "10.0.0.1": "", "x..com": ""} {
		if got := CookieDomainAll(host); got != want {
			t.Errorf("CookieDomainAll(%q) = %q, want %q", host, got, want)
		}
	}
	if got := AddYears(time.Date(2028, 2, 29, 1, 0, 0, 0, time.UTC), 10); !got.Equal(time.Date(2038, 2, 28, 1, 0, 0, 0, time.UTC)) {
		t.Errorf("Feb 29 + 10 years = %v", got)
	}
}

func TestDeleteCookieMatchesRails(t *testing.T) {
	var responses map[string]struct {
		Headers map[string]string
	}
	loadFixture(t, "rails_responses.json", &responses)
	if got, want := DeleteCookieLine("current_seller_id", "gumroad.com", true), responses["delete_seller"].Headers["set-cookie"]; got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestAnalyticsTokensVerifyLikeMessageVerifier(t *testing.T) {
	var fixture struct {
		SecretKeyBase string `json:"secret_key_base"`
		Valid         string
		Expired       string
		ScriptPurpose string `json:"script_purpose"`
		NoExpiry      string `json:"no_expiry"`
	}
	loadFixture(t, "analytics_tokens.json", &fixture)
	v, err := NewMessageVerifier(fixture.SecretKeyBase, "product_analytics_view")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	for name, token := range map[string]string{"valid": fixture.Valid, "no_expiry": fixture.NoExpiry} {
		data, ok := v.Verified(token, "external_landing_page_view", now)
		var payload map[string]any
		json.Unmarshal(data, &payload)
		if !ok || payload["source_url"] != "https://example.com/landing?a=1" || payload["event_id"] != "11111111-2222-4333-8444-555555555555" {
			t.Errorf("%s: %s %v", name, data, ok)
		}
	}
	for name, token := range map[string]string{
		"expired":       fixture.Expired,
		"other purpose": fixture.ScriptPurpose,
		"tampered":      fixture.Valid[:10] + "x" + fixture.Valid[11:],
		"no digest":     fixture.Valid[:len(fixture.Valid)-42],
		"empty":         "",
	} {
		if _, ok := v.Verified(token, "external_landing_page_view", now); ok {
			t.Errorf("%s verified", name)
		}
	}
}

func TestPublicPagesMatchTheRepository(t *testing.T) {
	for _, name := range []string{"404.html", "422.html", "500.html"} {
		repo, err := os.ReadFile("../../../public/" + name)
		if os.IsNotExist(err) {
			t.Skip("not in a full checkout")
		}
		embedded, _ := publicPages.ReadFile("public/" + name)
		if string(repo) != string(embedded) {
			t.Errorf("public/%s drifted from the repository's copy", name)
		}
	}
}

func TestFormatsFollowMimeNegotiation(t *testing.T) {
	for _, c := range []struct {
		format, accept, path string
		xhr                  bool
		want                 []string
		vary                 bool
	}{
		{accept: "application/json, text/html", want: []string{"json", "html"}, vary: true},
		{accept: "text/html,application/xhtml+xml,image/webp,*/*;q=0.8", want: []string{"html"}},
		{accept: "*/*", want: []string{"*/*"}, vary: true},
		{accept: "", want: []string{"html"}},
		{accept: "text/html;q=0.5, application/json", want: []string{"json", "html"}, vary: true},
		{format: "gif", accept: "image/avif,image/webp,*/*", want: []string{"gif"}},
		{format: "nope", accept: "application/json", want: nil},
		{accept: "application/vnd.custom+json", want: nil, vary: true},
		{accept: "", xhr: true, want: []string{"js"}},
		// q is String#to_f: an exponent counts, and a second dot ends the number.
		{accept: "text/html;q=1e-1, application/json;q=0.5", want: []string{"json", "html"}, vary: true},
		{accept: "text/html;q=0.5.1, application/json;q=0.4", want: []string{"html", "json"}, vary: true},
		// Past int64, (q * 100).to_i is a Bignum, which still orders.
		{accept: "text/html;q=1e19, application/json;q=1e20", want: []string{"json", "html"}, vary: true},
	} {
		var format any
		if c.format != "" {
			format = c.format
		}
		got, vary, err := formats(format, c.accept, "", c.xhr, c.path)
		if err != nil || !reflect.DeepEqual(got, c.want) || vary != c.vary {
			t.Errorf("%+v: got %v %v %v", c, got, vary, err)
		}
	}
	// (q.to_f * 100).to_i raises on an infinite quality in a list, including one that only
	// the multiplication makes infinite; a single type drops its q.
	for _, accept := range []string{"text/html;q=1e400, application/json", "text/html;q=1e307, application/json"} {
		if _, _, err := formats(nil, accept, "", false, ""); !errors.Is(err, ErrFailsafe) {
			t.Errorf("%s: %v", accept, err)
		}
	}
	if _, _, err := formats(nil, "garbage", "", false, ""); err == nil {
		t.Error("an Accept Mime::Type rejects is a 406")
	}
}

func TestRubyValueSemantics(t *testing.T) {
	for v, want := range map[any]bool{"": true, "   ": true, "x": false, false: true, true: false, json.Number("0"): false} {
		if Blank(v) != want {
			t.Errorf("blank(%#v) = %v", v, !want)
		}
	}
	for _, c := range []struct {
		in   any
		want any
	}{
		{"0", false}, {"false", false}, {"off", false}, {json.Number("0"), false}, {json.Number("0.0"), false},
		{"true", true}, {"yes", true}, {json.Number("2"), true}, {[]any{}, true},
	} {
		if got := BooleanCast(c.in); got == nil || *got != c.want {
			t.Errorf("BooleanCast(%#v) = %v", c.in, got)
		}
	}
	if BooleanCast("") != nil || BooleanCast(nil) != nil {
		t.Error(`"" and nil cast to nil`)
	}
	if got, ok := ColumnString(true); !ok || *got != "t" {
		t.Errorf("true is stored as %q", *got)
	}
	if _, ok := ColumnString([]any{"a"}); ok {
		t.Error("an array is not a string")
	}
	for in, want := range map[string]int64{"  -1_234abc": -1234, "12__3": 12, "_1": 0, "0d12": 12, "-0D1_2": -12, "0d_12": 0, "0d": 0, "00d12": 0, "0x12": 0, "9223372036854775807": 9223372036854775807, "-9223372036854775808": -9223372036854775808} {
		if got, ok := StringToI(in); !ok || got != want {
			t.Errorf("StringToI(%q) = %d %v", in, got, ok)
		}
	}
	for _, in := range []string{"9223372036854775808", strings.Repeat("9", 100000)} {
		if _, ok := StringToI(in); ok {
			t.Errorf("StringToI(%.20q) is a Bignum", in)
		}
	}
	if got := ToS(json.Number(strings.Repeat("7", 100000))); len(got) != 100000 {
		t.Error("an integer literal is its own to_s")
	}
	if ToS(json.Number("-0")) != "0" || ToS(json.Number("1E2")) != "100.0" || ToS(json.Number("1e400")) != "Infinity" {
		t.Error("number literals")
	}
}

func TestDateTimeParseMatchesToDatetime(t *testing.T) {
	var cases []struct {
		Input  string
		Time   string
		Offset int
		Nil    bool
		Error  string
	}
	loadFixture(t, "datetime_parse.json", &cases)
	for _, c := range cases {
		got, err := DateTimeParse(c.Input, testNow)
		switch {
		case c.Error != "":
			if _, ok := err.(TimeArgumentError); !ok {
				t.Errorf("%q: Ruby raised %q, got %v %v", c.Input, c.Error, got, err)
			}
		case c.Nil:
			if got != nil || err != nil {
				t.Errorf("%q: Ruby returned nil, got %v %v", c.Input, got, err)
			}
		default:
			want, _ := time.Parse(time.RFC3339Nano, c.Time)
			_, offset := got.Zone()
			if err != nil || got == nil || !got.Equal(want) || offset != c.Offset {
				t.Errorf("%q: got %v %v, want %v (offset %d)", c.Input, got, err, want, c.Offset)
			}
		}
	}
	if got, _ := DateTimeParse("10:30", testNow); got == nil || !got.Equal(time.Date(2026, 11, 2, 10, 30, 0, 0, time.UTC)) {
		t.Errorf("a time alone takes today's date: %v", got)
	}
}

// rubyInspect is Ruby 3.4's #inspect for parsed params, for comparing with the fixtures.
func rubyInspect(v any) string {
	switch v := v.(type) {
	case nil:
		return "nil"
	case string:
		var b strings.Builder
		b.WriteByte('"')
		for i := 0; i < len(v); {
			r, size := utf8.DecodeRuneInString(v[i:])
			switch {
			case r == utf8.RuneError && size == 1:
				fmt.Fprintf(&b, `\x%02X`, v[i])
			case r == '"' || r == '\\':
				b.WriteString(`\` + string(r))
			case r == '\n':
				b.WriteString(`\n`)
			case r < 0x20:
				fmt.Fprintf(&b, `\u%04X`, r)
			default:
				b.WriteRune(r)
			}
			i += size
		}
		b.WriteByte('"')
		return b.String()
	case bool, json.Number:
		return ToS(v)
	case []any:
		parts := make([]string, len(v))
		for i, item := range v {
			parts[i] = rubyInspect(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *Hash:
		if v.Len() == 0 {
			return "{}"
		}
		parts := make([]string, len(v.keys))
		for i, k := range v.keys {
			parts[i] = rubyInspect(k) + " => " + rubyInspect(v.values[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(v)
}

func TestStringToF(t *testing.T) {
	cases := map[string]struct {
		want  float64
		exact bool
	}{
		"12.5": {12.5, true}, " -3.25x": {-3.25, true}, ".5": {0.5, true}, "abc": {0, true}, "": {0, true},
		"0.8;x=1": {0.8, true}, "1e-1": {0.1, true},
		// Ruby 3.4 reads these differently from a plain decimal parse, or keeps fewer digits.
		"1_000.5": {1000.5, false}, "1.e5": {1, false}, "1e1_0": {10, false}, "-0x1p3": {0, false},
		"e5": {0, true}, "1" + strings.Repeat("0", 70) + "x": {1e70, false}, "1e400": {math.Inf(1), false}, "0x1A": {0, false},
	}
	for input, want := range cases {
		if got, exact := StringToF(input); got != want.want || exact != want.exact {
			t.Errorf("StringToF(%q) = %v %v, want %v %v", input, got, exact, want.want, want.exact)
		}
	}
}
