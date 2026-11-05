package delivery

import (
	"encoding/json"
	"os"
	"testing"
)

// testdata/s3_names.json is S3Retrievable's answers, from its own code under Ruby 3.4.
func TestS3NamesMatchRuby(t *testing.T) {
	var fixture struct {
		S3BaseURL string `json:"s3_base_url"`
		Owner     string
		Cases     []struct {
			URL              *string
			S3               bool
			Filename         *string
			Extension        *string
			DisplayExtension *string `json:"display_extension"`
			DisplayName      *string `json:"display_name"`
		}
	}
	b, err := os.ReadFile("testdata/s3_names.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, c := range fixture.Cases {
		url := ""
		if c.URL != nil {
			url = *c.URL
		}
		n := s3Names{url: url, baseURL: fixture.S3BaseURL, ownerExternalID: fixture.Owner}
		if n.s3() != c.S3 {
			t.Errorf("%q: s3 %v", url, n.s3())
			continue
		}
		if !c.S3 {
			continue
		}
		ext, ok := n.displayExtension()
		got := []string{n.filename(), n.extension(), n.displayName()}
		want := []string{*c.Filename, *c.Extension, *c.DisplayName}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("%q: field %d got %q want %q", url, i, got[i], want[i])
			}
		}
		if ok && ext != *c.DisplayExtension {
			t.Errorf("%q: display extension %q want %q", url, ext, *c.DisplayExtension)
		}
	}
}
