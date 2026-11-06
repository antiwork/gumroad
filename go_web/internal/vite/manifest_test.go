package vite

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// production_tags.json is what the inertia layout rendered in production for the
// manifest entries in testdata, with the Link header the same response carried.
func TestTagsMatchProduction(t *testing.T) {
	var want struct{ Stylesheet, Script, Link string }
	b, err := os.ReadFile("testdata/production_tags.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &want); err != nil {
		t.Fatal(err)
	}
	m, err := LoadDir("https://assets.gumroad.com", "testdata")
	if err != nil {
		t.Fatal(err)
	}
	style, err := m.EntrypointStylesheet("design")
	if err != nil {
		t.Fatal(err)
	}
	script, err := m.TypescriptTag("base")
	if err != nil {
		t.Fatal(err)
	}
	if style.HTML != want.Stylesheet {
		t.Errorf("stylesheet:\n got %s\nwant %s", style.HTML, want.Stylesheet)
	}
	if script.HTML != want.Script {
		t.Errorf("script:\n got %s\nwant %s", script.HTML, want.Script)
	}
	if link := LinkHeader(style, script); link != want.Link {
		t.Errorf("link:\n got %s\nwant %s", link, want.Link)
	}
}

func TestLinkHeaderStopsAtItsSize(t *testing.T) {
	a, b := strings.Repeat("a", 600), strings.Repeat("b", 500)
	// The second link would pass 1000 bytes, so that call tries nothing after it; the next
	// helper's call still adds what fits.
	got := LinkHeader(Tags{Links: []string{a, b, "c"}}, Tags{Links: []string{"d"}})
	if got != a+",d" {
		t.Fatalf("got %d bytes: %.20s", len(got), got)
	}
}

func TestMissingEntrypointAndImport(t *testing.T) {
	m, err := LoadDir("", "testdata")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.TypescriptTag("nope"); err == nil {
		t.Error("a missing entrypoint rendered")
	}
	dir := t.TempDir()
	if _, err := LoadDir("", dir); err == nil {
		t.Error("a directory without manifests loaded")
	}
	if err := os.WriteFile(dir+"/manifest.json", []byte(`{"a.ts":{"file":"a.js","imports":["_gone.js"]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadDir("", dir); err == nil {
		t.Error("a manifest importing a missing chunk loaded")
	}
}

// vite_asset_path looks a name with a directory up as it is, then path_to_asset adds the host.
func TestAssetPath(t *testing.T) {
	m, err := LoadDir("https://assets.gumroad.com", "testdata")
	if err != nil {
		t.Fatal(err)
	}
	if got, err := m.AssetPath("components/ui/Calendar.tsx"); err != nil || got != "https://assets.gumroad.com/vite/assets/Calendar-abc123.js" {
		t.Errorf("%q %v", got, err)
	}
	if _, err := m.AssetPath("components/ui/Missing.tsx"); err == nil {
		t.Error("a missing asset resolved")
	}
}

// import_chunks_for lists a chunk after what it imports and skips one it has seen.
func TestImportOrder(t *testing.T) {
	dir := t.TempDir()
	manifest := `{
		"entrypoints/x.ts": {"file": "x.js", "imports": ["_a.js", "_b.js", "_a.js"], "css": ["x.css"]},
		"_a.js": {"file": "a.js", "imports": ["_c.js"], "css": ["a.css", "x.css"]},
		"_b.js": {"file": "b.js", "imports": ["_c.js"]},
		"_c.js": {"file": "c.js", "css": ["c.css"]}
	}`
	if err := os.WriteFile(dir+"/manifest.json", []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	m, err := LoadDir("", dir)
	if err != nil {
		t.Fatal(err)
	}
	r, err := m.resolve("x")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(r.imports, " "); got != "/vite/c.js /vite/a.js /vite/b.js" {
		t.Errorf("imports %s", got)
	}
	if got := strings.Join(r.stylesheets, " "); got != "/vite/x.css /vite/c.css /vite/a.css" {
		t.Errorf("stylesheets %s", got)
	}
}
