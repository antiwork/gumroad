package inertia

import (
	"html"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/vite"
)

// testdata/production_expired_page.html is an expired page production rendered through the
// inertia layout, with the buyer's details replaced; its manifest is ../vite/testdata's.
func TestLayoutMatchesProduction(t *testing.T) {
	want, err := os.ReadFile("testdata/production_expired_page.html")
	if err != nil {
		t.Fatal(err)
	}
	wantLink, err := os.ReadFile("testdata/production_expired_page.link")
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := rails.ParseJSON([]byte(html.UnescapeString(regexp.MustCompile(`data-page="([^"]*)"`).FindStringSubmatch(string(want))[1])))
	if err != nil {
		t.Fatal(err)
	}
	page := parsed.(*rails.Hash)
	// The props without _inertia_meta, which Render adds from the tags it renders.
	props := rails.NewRHash()
	captured := page.Value("props").(*rails.Hash)
	for _, k := range captured.Keys() {
		if k != "_inertia_meta" {
			props.Str(k, captured.Value(k))
		}
	}
	csrf := regexp.MustCompile(`name="csrf-token" content="([^"]+)"`).FindStringSubmatch(string(want))[1]

	manifest, err := vite.LoadDir("https://assets.gumroad.com", "../vite/testdata")
	if err != nil {
		t.Fatal(err)
	}
	layout, err := NewLayout(LayoutConfig{
		OGNamespace:    "gumroad",
		DNSPrefetch:    []string{"https://assets.gumroad.com", "https://static-2.gumroad.com", "https://public-files.gumroad.com"},
		ActionCableURL: "wss://cable.gumroad.com/cable",
		Manifest:       manifest,
	})
	if err != nil {
		t.Fatal(err)
	}
	meta := productionMeta.Tags(Viewer{CSRFToken: csrf})
	meta.Set(NewMetaTag("", "", "", Attr{Key: "title", Value: "Watch-only video - Access expired"}))
	got := layout.Render(Document{
		Component:      page.Value("component").(string),
		URL:            page.Value("url").(string),
		Props:          props,
		Meta:           meta,
		UserAgent:      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
		DesignSettings: rails.EncodeJSON(rails.NewRHash().Sym("font", rails.NewRHash().Sym("name", "ABC Favorit").Sym("url", "https://assets.gumroad.com/fonts/ABCFavorit-Regular.woff2"))),
		UserAgentInfo:  rails.EncodeJSON(rails.NewRHash().Sym("is_mobile", false)),
	})
	if got != string(want) {
		gl, wl := strings.Split(got, "\n"), strings.Split(string(want), "\n")
		for i := 0; i < len(gl) && i < len(wl); i++ {
			if gl[i] != wl[i] {
				t.Fatalf("line %d differs:\n got %q\nwant %q", i+1, gl[i], wl[i])
			}
		}
		t.Fatalf("%d lines, want %d", len(gl), len(wl))
	}
	if link := layout.LinkHeader(); link != strings.TrimSpace(string(wantLink)) {
		t.Errorf("link:\n got %s\nwant %s", link, wantLink)
	}
}

func TestLayoutBodyAttributes(t *testing.T) {
	manifest, err := vite.LoadDir("", "../vite/testdata")
	if err != nil {
		t.Fatal(err)
	}
	layout, err := NewLayout(LayoutConfig{Manifest: manifest, DNSPrefetch: []string{"", "https://cdn.example.com:8443/x"}})
	if err != nil {
		t.Fatal(err)
	}
	got := layout.Render(Document{Component: "C", URL: "/u?a=1&b='", Props: rails.NewRHash().Sym("a", `"'`), Meta: NewMetaTags(), UserAgent: "Mobile", AsEmbed: true, BodyClass: "iframe"})
	for _, want := range []string{
		// URI.parse("").host is nil, which Ruby interpolates as "".
		"<head prefix=\"og: http://ogp.me/ns# fb: http://ogp.me/ns/fb# : http://ogp.me/ns/fb/#\">\n    <link rel=\"dns-prefetch\" href=\"//\">\n    <link rel=\"dns-prefetch\" href=\"//cdn.example.com\">\n  <meta",
		`<body id="" class="group/body iframe" style="background: transparent">`,
		`data-page="{&quot;component&quot;:&quot;C&quot;,&quot;props&quot;:{&quot;a&quot;:&quot;\&quot;&#39;&quot;,&quot;_inertia_meta&quot;:[]},&quot;url&quot;:&quot;/u?a=1\u0026b=&#39;&quot;`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %s", want)
		}
	}
}

var productionMeta = DefaultMeta{
	Title:                  "Gumroad",
	Environment:            "production",
	FacebookAppID:          "149071038533330",
	StripePublicKey:        "pk_live_Db80xIzLPWhKo1byPrnERmym",
	StripeAPIVersion:       "2023-10-16; risk_in_requirements_beta=v1; retrieve_tax_forms_beta=v1;",
	AssetHost:              "https://assets.gumroad.com",
	AnalyticsByEnvironment: true,
}

func TestScriptMetaTagsCarryTheirHashRaw(t *testing.T) {
	tags := NewMetaTags()
	tags.Set(NewMetaTag("script", "structured-data", "application/ld+json",
		Attr{Key: "inner_content", JSON: rails.NewRHash().Str("a", "<b>")}))
	tags.Set(NewMetaTag("script", "other", "text/javascript", Attr{Key: "inner_content", Value: "<b>"}))
	if got, want := tags.HTML(), `<script type="application/ld+json" inertia="structured-data">{"a":"\u003cb\u003e"}</script>`+"\n"+
		`<script type="text/plain" inertia="other">&lt;b&gt;</script>`; got != want {
		t.Errorf("HTML:\n%s\nwant\n%s", got, want)
	}
	if got, want := rails.EncodeJSON(tags.JSON()), `[{"tagName":"script","headKey":"structured-data","type":"application/ld+json",`+
		`"innerContent":{"a":"\u003cb\u003e"}},{"tagName":"script","headKey":"other","type":"text/plain","innerContent":"\u003cb\u003e"}]`; got != want {
		t.Errorf("JSON:\n%s\nwant\n%s", got, want)
	}
}
