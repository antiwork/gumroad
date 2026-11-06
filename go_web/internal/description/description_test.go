package description

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// fixtureCase is one description through the oracle in the fixture generator, which runs
// the app's own methods. A *Error field names the exception Ruby raised instead.
type fixtureCase struct {
	Kind          string  `json:"kind"`
	Input         string  `json:"input"`
	HTML          *string `json:"html"`
	HTMLError     string  `json:"html_error"`
	Plain         *string `json:"plain"`
	PlainError    string  `json:"plain_error"`
	Meta          *string `json:"meta"`
	MetaError     string  `json:"meta_error"`
	Strip         *string `json:"strip"`
	StripError    string  `json:"strip_error"`
	Struct        *string `json:"struct"`
	StructError   string  `json:"struct_error"`
	StripRaw      *string `json:"strip_raw"`
	StripRawError string  `json:"strip_raw_error"`
}

type fixtureFile struct {
	KnownReviewIDs []string      `json:"known_review_ids"`
	CDNMap         [][2]string   `json:"cdn_map"`
	Protocol       string        `json:"protocol"`
	Cases          []fixtureCase `json:"cases"`
	Texts          []struct {
		Text    string `json:"text"`
		Snippet string `json:"snippet"`
		Twitter string `json:"twitter"`
		Squish  string `json:"squish"`
	} `json:"texts"`
}

func loadFixtures(t *testing.T) fixtureFile {
	t.Helper()
	data, err := testfiles.Read("testdata/descriptions.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var f fixtureFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) == 0 || len(f.Texts) == 0 {
		t.Fatal("no fixtures")
	}
	return f
}

func (f fixtureFile) config() Config {
	return Config{
		CDNMap:   f.CDNMap,
		Protocol: f.Protocol,
		ReviewExists: func(id string) (bool, error) {
			return slices.Contains(f.KnownReviewIDs, id), nil
		},
	}
}

type tally struct{ native, total map[string]int }

// checkCase compares every function with Ruby on one case and reports whether all of
// them answered natively.
func checkCase(t *testing.T, c Config, fc fixtureCase) bool {
	t.Helper()
	native := true
	unported := func(err error, what string) bool {
		if errors.Is(err, ErrUnported) {
			native = false
			return true
		}
		if err != nil {
			t.Errorf("%s(%q): %v", what, fc.Input, err)
			return true
		}
		return false
	}
	want := func(what string, got string, want *string, rubyError string) {
		if rubyError != "" {
			t.Errorf("%s(%q) = %q, but Ruby raises %s", what, fc.Input, got, rubyError)
		} else if want == nil || got != *want {
			t.Errorf("%s(%q):\n got  %q\n want %v", what, fc.Input, got, show(want))
		}
	}

	html, present, htmlErr := HTML(fc.Input, c)
	if !unported(htmlErr, "HTML") {
		if fc.HTMLError == "" && present != (fc.HTML != nil) {
			t.Errorf("HTML(%q) present = %v, want %v", fc.Input, present, fc.HTML != nil)
		} else if present {
			want("HTML", html, fc.HTML, fc.HTMLError)
		}
		if strip, err := StripTagsSquished(html); !unported(err, "StripTagsSquished") {
			want("StripTagsSquished(HTML)", strip, fc.Strip, fc.StripError)
			var snippet *string
			if s := Snippet(strip); s != "" {
				snippet = &s
			}
			if fc.StructError == "" && show(snippet) != show(fc.Struct) {
				t.Errorf("Snippet(StripTagsSquished(HTML(%q))) = %v, want %v", fc.Input, show(snippet), show(fc.Struct))
			}
		}
	}

	plain, plainErr := Plaintext(fc.Input, c)
	if !unported(plainErr, "Plaintext") {
		want("Plaintext", plain, fc.Plain, fc.PlainError)
		meta := "Available on Gumroad"
		if !rails.Blank(fc.Input) {
			meta = plain
		}
		want("Snippet(meta)", Snippet(meta), fc.Meta, fc.MetaError)
	}

	if strip, err := StripTagsSquished(fc.Input); !unported(err, "StripTagsSquished") {
		want("StripTagsSquished", strip, fc.StripRaw, fc.StripRawError)
	}

	if got, want := HTMLAndPlaintext(fc.Input, c), (Both{html, present, htmlErr, plain, plainErr}); got != want {
		t.Errorf("HTMLAndPlaintext(%q) = %+v, want %+v", fc.Input, got, want)
	}
	return native
}

func show(s *string) string {
	if s == nil {
		return "nil"
	}
	b, _ := json.Marshal(*s)
	return string(b)
}

func (tl tally) add(kind string, native bool) {
	tl.total[kind]++
	if native {
		tl.native[kind]++
	}
}

func (tl tally) log(t *testing.T) {
	kinds := make([]string, 0, len(tl.total))
	for k := range tl.total {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	all, allNative := 0, 0
	for _, k := range kinds {
		t.Logf("%s: %d/%d native", k, tl.native[k], tl.total[k])
		all += tl.total[k]
		allNative += tl.native[k]
	}
	t.Logf("all: %d/%d native", allNative, all)
}

func TestDescriptionsMatchRails(t *testing.T) {
	f := loadFixtures(t)
	c := f.config()
	tl := tally{map[string]int{}, map[string]int{}}
	for _, fc := range f.Cases {
		tl.add(fc.Kind, checkCase(t, c, fc))
	}
	tl.log(t)
	if tl.native["editor"] < tl.total["editor"]*99/100 {
		t.Errorf("only %d/%d editor descriptions native", tl.native["editor"], tl.total["editor"])
	}
}

func TestTextCutsMatchRails(t *testing.T) {
	for _, tc := range loadFixtures(t).Texts {
		if got := Snippet(tc.Text); got != tc.Snippet {
			t.Errorf("Snippet(%q) = %q, want %q", tc.Text, got, tc.Snippet)
		}
		if got := TwitterDescription(tc.Text); got != tc.Twitter {
			t.Errorf("TwitterDescription(%q) = %q, want %q", tc.Text, got, tc.Twitter)
		}
		if got := Squish(tc.Text); got != tc.Squish {
			t.Errorf("Squish(%q) = %q, want %q", tc.Text, got, tc.Squish)
		}
	}
}

// DESCRIPTION_DIFF_FILE points at a JSON-lines file from the same generator, for large
// local runs.
func TestDifferentialFile(t *testing.T) {
	path := os.Getenv("DESCRIPTION_DIFF_FILE")
	if path == "" {
		t.Skip("DESCRIPTION_DIFF_FILE not set")
	}
	c := loadFixtures(t).config()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	tl := tally{map[string]int{}, map[string]int{}}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(nil, 64<<20)
	for scanner.Scan() {
		var fc fixtureCase
		if err := json.Unmarshal(scanner.Bytes(), &fc); err != nil {
			t.Fatal(err)
		}
		tl.add(fc.Kind, checkCase(t, c, fc))
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	tl.log(t)
}

func TestReviewCardNeedsTheLookup(t *testing.T) {
	c := Config{Protocol: "https"}
	if _, _, err := HTML(`<p>x</p><review-card reviewid="a"></review-card>`, c); !errors.Is(err, ErrUnported) {
		t.Fatalf("a review-card without ReviewExists: err = %v, want ErrUnported", err)
	}
	// Inside a removed element it never reaches the output, so the lookup is skipped.
	if got, _, err := HTML(`<p>x</p><font><review-card reviewid="a"></review-card></font>`, c); err != nil || got != "<p>x</p>" {
		t.Fatalf("got %q, %v", got, err)
	}

	boom := errors.New("db down")
	c.ReviewExists = func(id string) (bool, error) { return false, boom }
	if _, _, err := HTML(`<review-card reviewid="a"></review-card>`, c); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want the lookup's error", err)
	}

	var asked []string
	c.ReviewExists = func(id string) (bool, error) {
		asked = append(asked, id)
		return id == "a", nil
	}
	got, _, err := HTML(`<review-card reviewid="a" class="x"></review-card><review-card reviewid="b"></review-card><review-card></review-card>`+
		`<p><review-card reviewid="a"></review-card><review-card reviewid="b"></review-card></p>`, c)
	if err != nil || got != `<review-card reviewid="a"></review-card><p><review-card reviewid="a"></review-card></p>` {
		t.Fatalf("got %q, %v", got, err)
	}
	// Each reviewid is looked up once per description.
	if !slices.Equal(asked, []string{"a", "b", ""}) {
		t.Fatalf("looked up %q", asked)
	}
}

func TestCDNMapReplacementWithBackslashIsUnported(t *testing.T) {
	c := Config{CDNMap: [][2]string{{"https://a.example.com/", `https://b.example.com/\0`}}}
	if _, _, err := HTML("<p>x</p>", c); !errors.Is(err, ErrUnported) {
		t.Fatalf("err = %v, want ErrUnported", err)
	}
}

func TestBlankDescriptions(t *testing.T) {
	for _, d := range []string{"", " ", " \n", "　"} {
		if html, present, err := HTML(d, Config{}); err != nil || present || html != "" {
			t.Errorf("HTML(%q) = %q, %v, %v", d, html, present, err)
		}
		if plain, err := Plaintext(d, Config{}); err != nil || plain != "" {
			t.Errorf("Plaintext(%q) = %q, %v", d, plain, err)
		}
	}
}

// slowdown scales timing bounds; race_test.go raises it.
var slowdown = 1

// Descriptions run to about a megabyte (html4 takes up to 1 MiB); none of these may go
// quadratic.
func TestLargeAdversarialDescriptions(t *testing.T) {
	maxElapsed := 200 * time.Millisecond * time.Duration(slowdown)
	attrs := func(n int, prefix, value string) string {
		var b strings.Builder
		for i := range n {
			b.WriteString(" " + prefix + strconv.FormatInt(int64(i), 36) + "=" + value)
		}
		return b.String()
	}
	nested := func(tag string, depth int) string {
		return strings.Repeat("<"+tag+">", depth) + "x https://example.com" + strings.Repeat("</"+tag+">", depth)
	}
	inputs := map[string]string{
		"100k disallowed attributes":  "<p" + attrs(100_000, "a", "x") + ">x</p>",
		"75k data attributes":         "<p" + attrs(75_000, "data-", "x") + ">x</p>",
		"75k blank data attributes":   "<span" + attrs(75_000, "data-", `""`) + ">x</span>",
		"100k blank attributes":       "<span" + attrs(100_000, "a", `""`) + ">x</span>",
		"100k iframe attributes":      `<iframe src="https://cdn.iframe.ly/x"` + attrs(100_000, "a", "x") + "></iframe>",
		"100k upsell-card attributes": "<upsell-card" + attrs(100_000, "a", "x") + "></upsell-card>",
		"100k review-card attributes": `<review-card reviewid="a"` + attrs(100_000, "a", "x") + "></review-card>",
		"deep spans, repeated":        strings.Repeat(nested("span", 190), 400),
		"deep divs, repeated":         strings.Repeat(nested("div", 190), 400),
		"deep lists, repeated":        strings.Repeat(nested("ul", 190), 400),
		"20k review-cards":            strings.Repeat(`<review-card reviewid="a"></review-card>`, 20_000),
		"50k paragraphs":              strings.Repeat("<p>x</p>", 50_000),
		"40k links to autolink":       strings.Repeat("https://example.com/a ", 40_000),
		"10k iframes":                 strings.Repeat(`<iframe src="https://cdn.iframe.ly/x" style="position: absolute"></iframe>`, 10_000),
		"styles up to the budget":     strings.Repeat(`<p style="`+budgetStyle+`">x</p>`, maxStyleBudget/len(budgetStyle)),
	}
	c := Config{Protocol: "https", ReviewExists: func(string) (bool, error) { return true, nil }}
	for name, input := range inputs {
		var b Both
		elapsed := time.Duration(1 << 62)
		// The best of three keeps scheduler noise out of a bound meant to catch quadratic work.
		for range 3 {
			start := time.Now()
			b = HTMLAndPlaintext(input, c)
			// Autolinking can grow the HTML past html4's cap, which StripTagsSquished declines.
			if _, err := StripTagsSquished(b.HTML); err != nil && !errors.Is(err, ErrUnported) {
				t.Errorf("%s: StripTagsSquished: %v", name, err)
			}
			elapsed = min(elapsed, time.Since(start))
		}
		if b.HTMLErr != nil || b.PlaintextErr != nil {
			t.Errorf("%s (%d bytes): %v, %v", name, len(input), b.HTMLErr, b.PlaintextErr)
		}
		if elapsed > maxElapsed {
			t.Errorf("%s (%d bytes) took %v", name, len(input), elapsed)
		}
		t.Logf("%s: %d bytes in %v", name, len(input), elapsed)
	}
}

func TestManyDistinctReviewCardsAreRails(t *testing.T) {
	cards := func(n int) string {
		var b strings.Builder
		for i := range n {
			b.WriteString(`<review-card reviewid="r` + strconv.Itoa(i) + `"></review-card>`)
		}
		return b.String()
	}
	lookups := 0
	c := Config{Protocol: "https", ReviewExists: func(string) (bool, error) { lookups++; return true, nil }}
	if _, _, err := HTML(cards(maxReviewLookups), c); err != nil {
		t.Fatalf("%d cards: %v", maxReviewLookups, err)
	}
	lookups = 0
	if _, _, err := HTML(cards(maxReviewLookups+1), c); !errors.Is(err, ErrUnported) {
		t.Fatalf("%d cards: err = %v, want ErrUnported", maxReviewLookups+1, err)
	}
	if lookups != maxReviewLookups {
		t.Errorf("lookups = %d, want %d", lookups, maxReviewLookups)
	}
}

// budgetStyle is under csssan's cap for one style.
var budgetStyle = strings.Repeat("color: red; ", 1_000)

func TestStylesOverTheBudgetAreRails(t *testing.T) {
	input := strings.Repeat(`<p style="`+budgetStyle+`">x</p>`, maxStyleBudget/len(budgetStyle)+1)
	if b := HTMLAndPlaintext(input, Config{Protocol: "https"}); !errors.Is(b.HTMLErr, ErrUnported) {
		t.Fatalf("HTMLErr = %v, want ErrUnported", b.HTMLErr)
	}
}

func TestAStyleOverCSSsansCapIsRails(t *testing.T) {
	input := `<p style="` + strings.Repeat("color: red; ", 20_000) + `">x</p>`
	b := HTMLAndPlaintext(input, Config{Protocol: "https"})
	if !errors.Is(b.HTMLErr, ErrUnported) {
		t.Fatalf("HTMLErr = %v, want ErrUnported", b.HTMLErr)
	}
}
