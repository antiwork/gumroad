package customdomain

import (
	"compress/gzip"
	"encoding/json"
	"os"
	"regexp"
	"slices"
	"testing"
)

// The embedded list is the gem's at the version Rails runs. Bumping it means copying the gem's
// data/list.txt and rerunning testdata/generate_public_suffix_names.rb.
func TestTheListIsTheGemRailsRuns(t *testing.T) {
	lock, err := os.ReadFile("../../../Gemfile.lock")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`(?m)^    public_suffix \(5\.1\.1\)$`).Match(lock) {
		t.Error("Gemfile.lock no longer pins public_suffix 5.1.1")
	}
}

// Names answers as CustomDomain.find_by_host does, for hosts built from every rule in the list:
// testdata/public_suffix_names.json.gz is what the gem gave for each.
func TestNamesMatchThePublicSuffixGem(t *testing.T) {
	f, err := os.Open("testdata/public_suffix_names.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	var cases [][2]json.RawMessage
	if err := json.NewDecoder(r).Decode(&cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 30_000 {
		t.Fatalf("%d cases", len(cases))
	}
	failed := 0
	for _, c := range cases {
		var host string
		var want []string
		if err := json.Unmarshal(c[0], &host); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(c[1], &want); err != nil {
			t.Fatal(err)
		}
		if got := Names(host); !slices.Equal(got, want) {
			if failed++; failed <= 20 {
				t.Errorf("%q: got %q, want %q", host, got, want)
			}
		}
	}
	if failed > 0 {
		t.Errorf("%d of %d hosts differ", failed, len(cases))
	}
}
