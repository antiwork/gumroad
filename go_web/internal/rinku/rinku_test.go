package rinku

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

const productLinkAttr = `target="_blank" rel="noopener noreferrer nofollow"`

type fixture struct {
	Invalid [][]byte
	Cases   []struct {
		Input  string
		Attr   *string
		Output string
	}
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	data, err := testfiles.Read("testdata/autolink.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestAutoLinkMatchesRinku(t *testing.T) {
	f := loadFixture(t)
	if len(f.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range f.Cases {
		attr := productLinkAttr
		if c.Attr != nil {
			attr = *c.Attr
		}
		got, ok := AutoLink(c.Input, attr)
		if !ok || got != c.Output {
			t.Errorf("AutoLink(%q, %q) = %q, %v\nwant %q", c.Input, attr, got, ok, c.Output)
		}
	}
}

func TestAutoLinkDeclinesWhatRinkuRaisesOn(t *testing.T) {
	f := loadFixture(t)
	if len(f.Invalid) == 0 {
		t.Fatal("no invalid inputs")
	}
	for _, input := range f.Invalid {
		if got, ok := AutoLink(string(input), productLinkAttr); ok {
			t.Errorf("AutoLink(%q) = %q, want it declined", input, got)
		}
	}
}

// Each input once made every trigger in one long run rescan the rest of it: seconds per page
// view for a description this size.
func TestAutoLinkStaysLinearOnAdversarialInput(t *testing.T) {
	const size = 200_000
	const limit = 100 * time.Millisecond
	repeat := func(unit string) string { return strings.Repeat(unit, size/len(unit)) }
	for name, input := range map[string]string{
		"'@'s sharing an email run":     repeat("a@b-"),
		"'@'s after dots":               repeat(".@"),
		"urls inside the previous link": repeat("a@b.c.http://x.y/"),
		"urls cut by a tag":             repeat("http://a.b<>"),
		"unsafe schemes":                repeat("b://a.b"),
		"www hosts with underscores":    repeat("-www.a_"),
		"url host full of www":          "http://a" + repeat(".www") + "_a b",
	} {
		start := time.Now()
		AutoLink(input, productLinkAttr)
		if elapsed := time.Since(start); elapsed > limit {
			t.Errorf("%s: %v for %d bytes", name, elapsed, len(input))
		}
	}
}

func TestAutoLinkReturnsLargeInputWithoutLinksUnchanged(t *testing.T) {
	input := strings.Repeat("<p>plain &amp; simple, no addresses here.</p>", 10_000)
	if got, ok := AutoLink(input, productLinkAttr); !ok || got != input {
		t.Fatal("an input without links comes back as is")
	}
}
