// Package inertia renders what inertia_rails renders: the page object, the meta tags
// PageMeta sets through InertiaRails::MetaTag, and partial reloads.
package inertia

import (
	"crypto/md5"
	"encoding/hex"
	"regexp"
	"sort"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Attr is one tag_data entry, in the order set_meta_tag passed it.
type Attr struct{ Key, Value string }

// MetaTag is InertiaRails::MetaTag.
type MetaTag struct {
	tagName, headKey, typ string
	data                  []Attr
}

// NewMetaTag is MetaTag.new(tag_name:, head_key:, type:, **data). tagName "" is :meta; a
// meta with only a title is the title tag.
func NewMetaTag(tagName, headKey, typ string, data ...Attr) MetaTag {
	t := MetaTag{tagName: tagName, typ: typ, data: data}
	if tagName == "" && len(data) == 1 && data[0].Key == "title" {
		t.tagName, t.data = "title", []Attr{{"inner_content", data[0].Value}}
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
				return "meta-" + key + "-" + parameterize(v)
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
	for _, a := range append([]Attr{{"tagName", t.tagName}, {"headKey", t.headKey}, {"type", t.typ}}, t.data...) {
		if rails.Present(a.Value) {
			h.Sym(camelizeLower(a.Key), a.Value)
		}
	}
	return h
}

var (
	nonParam  = regexp.MustCompile(`(?i)[^a-z0-9\-_]+`)
	dashRun   = regexp.MustCompile(`-{2,}`)
	dashEdges = regexp.MustCompile(`(?i)^-|-$`)
)

// parameterize is String#parameterize for ASCII input, which every head key here is.
func parameterize(s string) string {
	s = nonParam.ReplaceAllString(s, "-")
	s = dashRun.ReplaceAllString(s, "-")
	return strings.ToLower(dashEdges.ReplaceAllString(s, ""))
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

// JSON is the _inertia_meta prop.
func (m *MetaTags) JSON() []any {
	out := make([]any, len(m.keys))
	for i, k := range m.keys {
		out[i] = m.tags[k].JSON()
	}
	return out
}
