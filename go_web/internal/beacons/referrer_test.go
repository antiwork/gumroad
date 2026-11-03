package beacons

import (
	"encoding/json"
	"os"
	"testing"
)

func TestReferrerDomainMatchesExtractDomain(t *testing.T) {
	data, err := os.ReadFile("testdata/referrer_domains.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Input  string
		Domain string
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		input := c.Input
		if got := referrerDomain(&input); got != c.Domain {
			t.Errorf("%q: got %q, want %q", c.Input, got, c.Domain)
		}
	}
	if referrerDomain(nil) != "direct" {
		t.Error("nil is direct")
	}
}
