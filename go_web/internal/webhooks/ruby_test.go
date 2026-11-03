package webhooks

import (
	"encoding/base64"
	"strconv"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

func TestRubyIntegerMatchesKernelInteger(t *testing.T) {
	for input, want := range rubyIntegerResults {
		got, ok := rubyInteger(input)
		switch {
		case want == "" && ok:
			t.Errorf("rubyInteger(%q) = %d, want an error", input, got)
		case want != "" && want != "99999999999999999999" && (!ok || strconv.FormatInt(got, 10) != want):
			t.Errorf("rubyInteger(%q) = %d, %v; want %s", input, got, ok, want)
		}
	}
	// Ruby makes a Bignum; the Stripe header parser refuses it instead.
	if _, ok := rubyInteger("99999999999999999999"); ok {
		t.Error("a value outside int64 was accepted")
	}
}

func TestRubyDecode64MatchesBase64Decode64(t *testing.T) {
	for input, want := range rubyDecode64Results {
		if got := base64.StdEncoding.EncodeToString(rubyDecode64(input)); got != want {
			t.Errorf("rubyDecode64(%q) = %s, want %s", input, got, want)
		}
	}
}

func TestRubyExtnameMatchesFileExtname(t *testing.T) {
	for input, want := range rubyExtnameResults {
		if got := rubyExtname(input); got != want {
			t.Errorf("rubyExtname(%q) = %q, want %q", input, got, want)
		}
	}
}

// The Stripe Connect checks lean on rails.Blank; it must agree with String#blank?, and a
// StripeObject, which has no empty?, is never blank.
func TestRailsBlankIsActiveSupportsBlank(t *testing.T) {
	for input, want := range rubyBlankResults {
		if got := rails.Blank(input); got != want {
			t.Errorf("rails.Blank(%q) = %v, want %v", input, got, want)
		}
	}
	if !rails.Present(sidekiq.Hash{}) {
		t.Error("an empty StripeObject must be present")
	}
}

func TestRubyParseURIMatchesURIParse(t *testing.T) {
	for input, want := range rubyURIResults {
		got, err := rubyParseURI(input)
		if want == nil {
			if err == nil {
				t.Errorf("rubyParseURI(%q) = %+v, want URI::InvalidURIError", input, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("rubyParseURI(%q) failed: %v", input, err)
			continue
		}
		if want.scheme != nil && got.scheme != *want.scheme || want.scheme == nil && got.scheme != "" {
			t.Errorf("rubyParseURI(%q).scheme = %q, want %v", input, got.scheme, deref(want.scheme))
		}
		if want.host != nil != got.hasHost || want.host != nil && got.host != *want.host {
			t.Errorf("rubyParseURI(%q).host = %q (%v), want %v", input, got.host, got.hasHost, deref(want.host))
		}
		if want.query != nil != (got.query != nil) || want.query != nil && *got.query != *want.query {
			t.Errorf("rubyParseURI(%q).query = %v, want %v", input, deref(got.query), deref(want.query))
		}
		// Only an https URI on an SNS host is ever fetched, from what Net::HTTP requests.
		if want.scheme != nil && *want.scheme == "https" && want.host != nil && want.path != nil && want.requestURI != nil {
			wantURL := "https://" + *want.host + *want.requestURI
			if want.port != 443 {
				wantURL = "https://" + *want.host + ":" + strconv.Itoa(want.port) + *want.requestURI
			}
			if *want.path != "" {
				if got := certFetchURL(got); got != wantURL {
					t.Errorf("certFetchURL(%q) = %q, want %q", input, got, wantURL)
				}
			}
		}
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return strconv.Quote(*s)
}

func TestRubyToF(t *testing.T) {
	cases := map[string]float64{"12.5": 12.5, " -3.25x": -3.25, ".5": 0.5, "1_000.5": 1000.5, "1.e5": 1, "abc": 0, "": 0}
	for input, want := range cases {
		if got := rubyToF(input); got != want {
			t.Errorf("rubyToF(%q) = %v, want %v", input, got, want)
		}
	}
}
