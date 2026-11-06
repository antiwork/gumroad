package products

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// testdata/simple_format.json.gz is ActionView 8.1.3.1's simple_format with the HTML4
// sanitizer (rails-html-sanitizer 1.6.2, Nokogiri 1.19.3) on markup-free text.
func TestSimpleFormatMatchesRails(t *testing.T) {
	data, err := testfiles.Read("testdata/simple_format.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct{ Input, Output string }
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	native := 0
	for _, c := range cases {
		got, err := simpleFormat(c.Input)
		var fb pages.Fallback
		switch {
		case errors.As(err, &fb):
		case err != nil:
			t.Errorf("%q: %v", c.Input, err)
		case got != c.Output:
			t.Errorf("%q:\n got %q\nwant %q", c.Input, got, c.Output)
		default:
			native++
		}
	}
	if native != len(cases) {
		t.Errorf("only %d of %d rendered here", native, len(cases))
	}
}

// The sanitizer's permit scrubber isn't ported, so markup is Rails'. An escaped < is text.
func TestSimpleFormatLeavesMarkupToRails(t *testing.T) {
	var fb pages.Fallback
	if _, err := simpleFormat("Refunds <b>within</b> 30 days"); !errors.As(err, &fb) {
		t.Errorf("markup: %v", err)
	}
	if got, err := simpleFormat("a &lt;b&gt; c"); err != nil || got != "<p>a &lt;b&gt; c</p>" {
		t.Errorf("escaped: %q %v", got, err)
	}
}
