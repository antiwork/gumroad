// Package inertia renders what inertia_rails renders: the page object, the meta tags
// PageMeta sets through InertiaRails::MetaTag, and partial reloads.
package inertia

import (
	"crypto/md5"
	"encoding/hex"
	"sort"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Attr is one tag_data entry, in the order set_meta_tag passed it. Value is what the tag
// helper writes; JSON, when set, is the value as_json carries instead (a Float), and a
// script's inner content is its JSON, encoded. Raw inner content is html_safe, written
// unescaped.
type Attr struct {
	Key, Value string
	JSON       any
	Raw        bool
}

// MetaTag is InertiaRails::MetaTag.
type MetaTag struct {
	tagName, headKey, typ string
	data                  []Attr
}

// ldJSONType is MetaTag::LD_JSON_TYPE; a script of any other type is text/plain.
const ldJSONType = "application/ld+json"

// NewMetaTag is MetaTag.new(tag_name:, head_key:, type:, **data). tagName "" is :meta; a
// meta with only a title is the title tag.
func NewMetaTag(tagName, headKey, typ string, data ...Attr) MetaTag {
	if tagName == "script" {
		if headKey == "" {
			// tag_digest would hash Ruby's Hash#to_s of the content.
			panic("inertia: a script meta tag needs a head key")
		}
		if typ != ldJSONType {
			typ = "text/plain"
		}
	}
	t := MetaTag{tagName: tagName, typ: typ, data: data}
	if tagName == "" && len(data) == 1 && data[0].Key == "title" {
		inner := data[0]
		inner.Key = "inner_content"
		t.tagName, t.data = "title", []Attr{inner}
	} else if tagName == "" {
		t.tagName = "meta"
	}
	switch {
	case t.tagName == "title":
		t.headKey = "title"
	case headKey != "":
		t.headKey = headKey
	default:
		t.headKey = t.generateHeadKey()
	}
	return t
}

func (t MetaTag) value(key string) (string, bool) {
	for _, a := range t.data {
		if a.Key == key {
			return a.Value, true
		}
	}
	return "", false
}

func (t MetaTag) generateHeadKey() string {
	if t.tagName == "meta" {
		if _, ok := t.value("charset"); ok {
			return "meta-charset"
		}
		for _, key := range []string{"name", "property", "http_equiv"} {
			if v, ok := t.value(key); ok {
				return "meta-" + key + "-" + rails.Parameterize(v)
			}
		}
	}
	return t.tagName + "-" + t.digest()
}

// digest is tag_digest: MD5 of the sorted key=value pairs.
func (t MetaTag) digest() string {
	pairs := make([]string, len(t.data))
	sorted := append([]Attr(nil), t.data...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Key < sorted[j].Key })
	for i, a := range sorted {
		pairs[i] = a.Key + "=" + a.Value
	}
	sum := md5.Sum([]byte(strings.Join(pairs, "&")))
	return hex.EncodeToString(sum[:])[:8]
}

// JSON is MetaTag#as_json: tagName, headKey and type, then the data with camelized keys,
// blank values dropped.
func (t MetaTag) JSON() *rails.RHash {
	h := rails.NewRHash()
	for _, a := range append([]Attr{{Key: "tagName", Value: t.tagName}, {Key: "headKey", Value: t.headKey}, {Key: "type", Value: t.typ}}, t.data...) {
		v := any(a.Value)
		if a.JSON != nil {
			v = a.JSON
		}
		if rails.Present(v) {
			h.Sym(camelizeLower(a.Key), v)
		}
	}
	return h
}

// camelizeLower is to_s.camelize(:lower) for snake_case keys.
func camelizeLower(s string) string {
	parts := strings.Split(s, "_")
	for i := 1; i < len(parts); i++ {
		if parts[i] != "" {
			parts[i] = strings.ToUpper(parts[i][:1]) + parts[i][1:]
		}
	}
	return strings.Join(parts, "")
}

// MetaTags is the controller's InertiaRails::MetaTagBuilder: one tag per head key, a
// replacement keeping the first one's place.
type MetaTags struct {
	keys []string
	tags map[string]MetaTag
}

func NewMetaTags() *MetaTags { return &MetaTags{tags: map[string]MetaTag{}} }

// Set is set_meta_tag.
func (m *MetaTags) Set(t MetaTag) {
	if _, ok := m.tags[t.headKey]; !ok {
		m.keys = append(m.keys, t.headKey)
	}
	m.tags[t.headKey] = t
}

// Title is the title tag's inner content, or its content, as page_title reads them.
func (m *MetaTags) Title() string {
	t, ok := m.tags["title"]
	if !ok {
		return ""
	}
	if v, _ := t.value("inner_content"); rails.Present(v) {
		return v
	}
	v, _ := t.value("content")
	return v
}

// PageTitle is PageMeta::Base#page_title: Title, else the default.
func (m *MetaTags) PageTitle(fallback string) string {
	if t := m.Title(); rails.Present(t) {
		return t
	}
	return fallback
}

// JSON is the _inertia_meta prop.
func (m *MetaTags) JSON() []any {
	out := make([]any, len(m.keys))
	for i, k := range m.keys {
		out[i] = m.tags[k].JSON()
	}
	return out
}
