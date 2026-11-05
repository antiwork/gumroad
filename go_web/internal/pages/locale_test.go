package pages

import (
	"encoding/json"
	"os"
	"testing"
)

// inexact are the fixture headers whose qualities this port leaves to Rails.
var inexact = map[string]bool{"en;q=1_0,de": true}

// testdata/locales.json is http_accept_language 2.1.1's answer for each header.
func TestLocaleMatchesTheGem(t *testing.T) {
	var cases []struct {
		Header *string
		Locale string
	}
	b, err := os.ReadFile("testdata/locales.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		header := ""
		if c.Header != nil {
			header = *c.Header
		}
		got, ok := Locale(header)
		if !ok && inexact[header] {
			continue
		}
		if !ok || got != c.Locale {
			t.Errorf("%q: got %q (%v), want %q", header, got, ok, c.Locale)
		}
	}
}

func TestLocaleLeavesMRIOrderingToRails(t *testing.T) {
	for _, h := range []string{"a,b,c,d,e,f,g", "en-é", "en;q=1.e-1,de;q=0.5", "en;q=0.5,de;q=+0x1p0"} {
		if _, ok := Locale(h); ok {
			t.Errorf("%q was decided", h)
		}
	}
	// Seven languages without a tie sort the same under any algorithm.
	if got, ok := Locale("a;q=0.1,b;q=0.2,c;q=0.3,d;q=0.4,e;q=0.5,f;q=0.6,g;q=0.7"); !ok || got != "g" {
		t.Errorf("got %q %v", got, ok)
	}
}
