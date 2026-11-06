// Package vite renders the asset tags a Rails layout gets from vite_rails, from the
// manifests the same build wrote (ViteRuby::Manifest, ViteRails::TagHelpers and the Action
// View tag helpers they call).
package vite

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// config/vite.json's production and staging publicOutputDir; development builds and
	// dev servers are left to Rails.
	publicOutputDir = "vite"
	entrypointsDir  = "entrypoints"
	// AssetTagHelper::MAX_HEADER_SIZE.
	maxLinkHeaderSize = 1000
)

// knownManifests are ViteRuby::Config#known_manifest_paths, in the order they merge.
var knownManifests = []string{"manifest.json", "manifest-assets.json"}

// Manifest is ViteRuby::Manifest after resolve_references: files carry /vite/ and imports
// point at their entries.
type Manifest struct {
	assetHost string
	entries   map[string]*entry
}

type entry struct {
	file    string
	css     []string
	imports []*entry
}

type rawEntry struct {
	File    string   `json:"file"`
	CSS     []string `json:"css"`
	Imports []string `json:"imports"`
}

// LoadDir reads the known manifests that exist in dir, the build's .vite, as
// manifest_paths does. assetHost is config.asset_host, which path_to_asset prefixes.
func LoadDir(assetHost, dir string) (*Manifest, error) {
	raw := map[string]rawEntry{}
	found := false
	for _, name := range knownManifests {
		p := path.Join(dir, name)
		b, err := os.ReadFile(p)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var part map[string]rawEntry
		if err := json.Unmarshal(b, &part); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		// inject(&:merge): a later file's entry replaces an earlier one's.
		for name, e := range part {
			raw[name] = e
		}
		found = true
	}
	if !found {
		return nil, fmt.Errorf("no Vite manifest in %s", dir)
	}
	m := &Manifest{assetHost: assetHost, entries: make(map[string]*entry, len(raw))}
	for name, e := range raw {
		resolved := &entry{file: prefix(e.File)}
		for _, css := range e.CSS {
			resolved.css = append(resolved.css, prefix(css))
		}
		m.entries[name] = resolved
	}
	for name, e := range raw {
		for _, imported := range e.Imports {
			target, ok := m.entries[imported]
			if !ok {
				// manifest.fetch raises while loading.
				return nil, fmt.Errorf("manifest entry %q imports missing %q", name, imported)
			}
			m.entries[name].imports = append(m.entries[name].imports, target)
		}
	}
	return m, nil
}

func prefix(file string) string { return path.Join("/", publicOutputDir, file) }

// resolved is resolve_entries for one name.
type resolved struct {
	script      string
	imports     []string
	stylesheets []string
}

// resolve is resolve_entries(name, type: :typescript) for a bare entrypoint name.
func (m *Manifest) resolve(name string) (*resolved, error) {
	key := name
	if path.Ext(key) == "" {
		key += ".ts"
	}
	if !strings.Contains(key, "/") {
		key = entrypointsDir + "/" + key
	}
	e, ok := m.entries[key]
	if !ok {
		return nil, fmt.Errorf("vite entrypoint %q is not in the manifest", key)
	}
	chunks := importChunks(e, map[string]bool{})
	r := &resolved{script: e.file}
	for _, c := range chunks {
		r.imports = append(r.imports, c.file)
	}
	seen := map[string]bool{}
	for _, c := range append([]*entry{e}, chunks...) {
		for _, css := range c.css {
			if !seen[css] {
				seen[css] = true
				r.stylesheets = append(r.stylesheets, css)
			}
		}
	}
	return r, nil
}

// importChunks is import_chunks_for: depth first, each chunk after the chunks it imports,
// none twice.
func importChunks(e *entry, seen map[string]bool) []*entry {
	var chunks []*entry
	for _, c := range e.imports {
		if seen[c.file] {
			continue
		}
		seen[c.file] = true
		chunks = append(chunks, importChunks(c, seen)...)
		chunks = append(chunks, c)
	}
	return chunks
}

func (m *Manifest) url(p string) string { return m.assetHost + p }

// AssetPath is vite_asset_path for a name with its extension and a directory, which
// resolve_entry_name looks up as it is.
func (m *Manifest) AssetPath(name string) (string, error) {
	e, ok := m.entries[name]
	if !ok {
		return "", fmt.Errorf("vite asset %q is not in the manifest", name)
	}
	return m.url(e.file), nil
}

// Tags is what one tag helper renders, and the links it adds to the Link header.
type Tags struct {
	HTML  string
	Links []string
}

// EntrypointStylesheet is ApplicationHelper#vite_entrypoint_stylesheet_tag(name,
// crossorigin: "anonymous"). An entrypoint without CSS falls back to a .scss lookup this
// port leaves out, so it errors.
func (m *Manifest) EntrypointStylesheet(name string) (Tags, error) {
	r, err := m.resolve(name)
	if err != nil {
		return Tags{}, err
	}
	if len(r.stylesheets) == 0 {
		return Tags{}, fmt.Errorf("vite entrypoint %q has no stylesheets", name)
	}
	const crossorigin = "anonymous"
	var t Tags
	tags := make([]string, len(r.stylesheets))
	for i, css := range r.stylesheets {
		href := m.url(css)
		t.Links = append(t.Links, "<"+href+">; rel=preload; as=style; crossorigin="+crossorigin+"; nopush")
		tags[i] = `<link rel="stylesheet" crossorigin="` + crossorigin + `" href="` + web.HTMLEscape(href) + `" />`
	}
	t.HTML = strings.Join(tags, "\n")
	return t, nil
}

// TypescriptTag is vite_typescript_tag(name, skip_style_tags: true): the module script,
// then a modulepreload link per imported chunk.
func (m *Manifest) TypescriptTag(name string) (Tags, error) {
	r, err := m.resolve(name)
	if err != nil {
		return Tags{}, err
	}
	src := m.url(r.script)
	var b strings.Builder
	b.WriteString(`<script src="` + web.HTMLEscape(src) + `" crossorigin="" type="module"></script>`)
	for i, imported := range r.imports {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(`<link rel="modulepreload" href="` + web.HTMLEscape(m.url(imported)) + `" as="script" crossorigin="">`)
	}
	return Tags{HTML: b.String(), Links: []string{"<" + src + ">; rel=modulepreload; as=script; crossorigin=; nopush"}}, nil
}

// LinkHeader is the Link header send_preload_links_header builds over a render's tags, in
// render order. Each helper's call stops at the first of its links that would take the
// header past its size; the next helper's call tries its own.
func LinkHeader(tags ...Tags) string {
	var b strings.Builder
	for _, t := range tags {
		for _, link := range t.Links {
			if b.Len()+len(link) > maxLinkHeaderSize {
				break
			}
			if b.Len() > 0 {
				b.WriteByte(',')
			}
			b.WriteString(link)
		}
	}
	return b.String()
}
