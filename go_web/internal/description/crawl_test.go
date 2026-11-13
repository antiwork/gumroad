package description

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// testdata/crawl_text.json.gz is crawl_text.rb's output: Loofah 2.25.1 and ActionView 8.1's
// answers for the corpus's sanitized descriptions and some hand-written ones.
func TestCrawlTextMatchesLoofah(t *testing.T) {
	data, err := testfiles.Read("testdata/crawl_text.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct{ HTML, Text, Formatted string }
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 800 {
		t.Fatalf("%d cases", len(cases))
	}
	unported := 0
	for _, c := range cases {
		got, err := CrawlText(c.HTML)
		if errors.Is(err, ErrUnported) {
			unported++
			continue
		}
		if err != nil {
			t.Fatalf("%q: %v", c.HTML, err)
		}
		if got != c.Text {
			t.Errorf("text of %q:\n got %q\nwant %q", c.HTML, got, c.Text)
			continue
		}
		if f := Paragraphs(web.HTMLEscape(got)); f != c.Formatted {
			t.Errorf("formatted %q:\n got %q\nwant %q", c.Text, f, c.Formatted)
		}
	}
	// The parser leaves a handful of malformed inputs to Rails; sanitized ones parse.
	if unported > len(cases)/50 {
		t.Errorf("%d of %d unported", unported, len(cases))
	}
}

func TestParagraphs(t *testing.T) {
	for in, want := range map[string]string{
		"":             "<p></p>",
		" \n ":         "<p></p>",
		"a":            "<p>a</p>",
		"a\nb":         "<p>a\n<br />b</p>",
		"a\n\nb":       "<p>a</p>\n\n<p>b</p>",
		"a\n\n\n\nb":   "<p>a</p>\n\n<p>b</p>",
		"a\r\nb\r\rc":  "<p>a\n<br />b</p>\n\n<p>c</p>",
		"\n\na":        "<p></p>\n\n<p>a</p>",
		"a\n\n":        "<p>a</p>",
		"a\nb\nc\n\nd": "<p>a\n<br />b\n<br />c</p>\n\n<p>d</p>",
	} {
		if got := Paragraphs(in); got != want {
			t.Errorf("Paragraphs(%q) = %q, want %q", in, got, want)
		}
	}
}
