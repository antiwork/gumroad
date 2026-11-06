package csssan

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// The fixtures come from running loofah 2.25.1 on crass 1.0.6 (Ruby 3.4) over hand-written
// and seeded random inputs, with "position" added to the safelist as Gumroad does.

func loadFixture(t *testing.T, name string, v any) {
	t.Helper()
	data, err := testfiles.Read("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

type cssCase struct {
	Style    string
	Scrubbed string
	Raises   string // Ruby raised, so the port must decline
	Decline  bool   // Ruby answers, but outside what the port matches
}

func TestScrubCSSMatchesLoofah(t *testing.T) {
	var cases []cssCase
	loadFixture(t, "css.json.gz", &cases)
	checkCSS(t, cases)
}

func checkCSS(t *testing.T, cases []cssCase) {
	t.Helper()
	declined := 0
	for _, c := range cases {
		got, err := ScrubCSS(c.Style)
		switch {
		case c.Raises != "" || c.Decline:
			declined++
			if !errors.Is(err, ErrUnported) {
				t.Errorf("%q: got %q, %v; want ErrUnported (raises %q)", c.Style, got, err, c.Raises)
			}
		case err != nil:
			t.Errorf("%q: %v, want %q", c.Style, err, c.Scrubbed)
		case got != c.Scrubbed:
			t.Errorf("%q: got %q, want %q", c.Style, got, c.Scrubbed)
		}
	}
	t.Logf("%d cases, %d declined", len(cases), declined)
}

type uriCase struct {
	URI     string
	Allowed bool
	Raises  string
}

func TestAllowedURIMatchesLoofah(t *testing.T) {
	var cases []uriCase
	loadFixture(t, "uris.json.gz", &cases)
	checkURIs(t, cases)
}

func checkURIs(t *testing.T, cases []uriCase) {
	t.Helper()
	for _, c := range cases {
		got, err := AllowedURI(c.URI)
		switch {
		case c.Raises != "":
			if !errors.Is(err, ErrUnported) {
				t.Errorf("%q: got %v, %v; want ErrUnported (raises %q)", c.URI, got, err, c.Raises)
			}
		case err != nil:
			t.Errorf("%q: %v, want %v", c.URI, err, c.Allowed)
		case got != c.Allowed:
			t.Errorf("%q: got %v, want %v", c.URI, got, c.Allowed)
		}
	}
}

// Data URIs in descriptions run to megabytes, but only the first few characters after the
// scheme decide them.
func TestLargeDataURIs(t *testing.T) {
	const size = 1 << 20
	base64 := strings.Repeat("iVBORw0KGgoAAAANSUhEUgAA+/", size/26)
	for _, c := range []struct {
		uri  string
		want bool
		// The rest strip a control character or decode a reference every few bytes, and
		// under -race each of those copies costs enough to blow a wall-clock budget.
		timed bool
	}{
		{"data:image/png;base64," + base64, true, true},
		{"DATA:IMAGE/PNG;base64," + base64, true, true},
		{"data:text/html;base64," + base64, false, true},
		{"data:" + strings.Repeat("a", size), false, true},
		{"data:" + strings.Repeat(";", size), true, true},
		{"data:image/png;base64," + strings.Repeat("iVBORw0KGgo AAAANSUhEUgAA\n", size/26), true, false},
		{"data:image/svg+xml," + strings.Repeat("%3Csvg viewBox=%220 0 24 24%22%3E%3C/svg%3E", size/42), false, false},
		{"data:image/svg+xml," + strings.Repeat("<svg>&amp;</svg>\n", size/17), false, false},
	} {
		elapsed := time.Hour
		for range 3 {
			start := time.Now()
			got, err := AllowedURI(c.uri)
			elapsed = min(elapsed, time.Since(start))
			if err != nil || got != c.want {
				t.Fatalf("%.30q...: got %v, %v; want %v", c.uri, got, err, c.want)
			}
		}
		if c.timed && elapsed > 10*time.Millisecond {
			t.Errorf("%.30q... took %v", c.uri, elapsed)
		}
	}
}

func TestInvalidUTF8IsDeclined(t *testing.T) {
	if _, err := ScrubCSS("color: \xffred"); !errors.Is(err, ErrUnported) {
		t.Errorf("ScrubCSS: got %v, want ErrUnported", err)
	}
	if _, err := AllowedURI("http://\xff"); !errors.Is(err, ErrUnported) {
		t.Errorf("AllowedURI: got %v, want ErrUnported", err)
	}
}

func TestDeepInputIsDeclinedWithoutRecursing(t *testing.T) {
	for _, style := range []string{
		"color: " + strings.Repeat("(", 1_000_000),
		"color: " + strings.Repeat(`\28`, 100_000),
		"color: red" + strings.Repeat("/**/", 100_000),
	} {
		if _, err := ScrubCSS(style); !errors.Is(err, ErrUnported) {
			t.Errorf("%.20q...: got %v, want ErrUnported", style, err)
		}
	}
}

func TestSafeListLookups(t *testing.T) {
	for _, c := range []struct {
		f    func(string) bool
		name string
		want bool
	}{
		{AllowedAttribute, "href", true},
		{AllowedAttribute, "style", true},
		{AllowedAttribute, "viewBox", true},
		{AllowedAttribute, "viewbox", true},
		{AllowedAttribute, "xlink:href", true},
		{AllowedAttribute, "onclick", false},
		{AllowedAttribute, "HREF", false},
		{AttrValIsURI, "src", true},
		{AttrValIsURI, "xlink:href", true},
		{AttrValIsURI, "style", false},
		{SVGAttrValAllowsRef, "fill", true},
		{SVGAttrValAllowsRef, "href", false},
	} {
		if got := c.f(c.name); got != c.want {
			t.Errorf("%q: got %v, want %v", c.name, got, c.want)
		}
	}
}
