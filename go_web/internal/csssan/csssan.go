// Package csssan reproduces Loofah::HTML5::Scrub.scrub_css and allowed_uri? (loofah 2.25.1
// on crass 1.0.6) byte for byte, with "position" allowed the way Link#description_scrubber
// allows it. Inputs it cannot match exactly return ErrUnported so the caller can fall back
// to Rails.
package csssan

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// ErrUnported means the input is outside what the port matches exactly; ask Rails.
var ErrUnported = errors.New("csssan: input not ported")

func init() {
	// Link#description_scrubber adds it to ACCEPTABLE_CSS_PROPERTIES, which is the same Set
	// as ALLOWED_CSS_PROPERTIES.
	allowedCSSProperties["position"] = true
}

// maxStyleBytes leaves larger styles to Rails: tokenizing allocates a few hundred bytes per
// byte of input.
const maxStyleBytes = 16 << 10

// ScrubCSS is Loofah::HTML5::Scrub.scrub_css(style).
func ScrubCSS(style string) (string, error) {
	if len(style) > maxStyleBytes || !utf8.ValidString(style) {
		return "", ErrUnported
	}
	p, items, err := parseProperties(style)
	if err != nil {
		return "", err
	}
	var out strings.Builder
	for _, it := range items {
		if it.kind != itemProperty || hasURL(it.children) {
			continue
		}
		name, ok := downcaseASCII(it.name)
		if !ok {
			// Ruby's downcase of the name is not ASCII, so only the shorthand check can pass,
			// and then the name is printed.
			first, _, _ := strings.Cut(it.name, "-")
			if first, ok := downcaseASCII(first); ok && shorthandCSSProperties[first] {
				return "", ErrUnported
			}
			continue
		}
		shorthand := isShorthand(name)
		if !allowedCSSProperties[name] && !allowedSVGProperties[name] && !shorthand {
			continue
		}

		var value strings.Builder
		for _, n := range it.children {
			switch {
			case n.is(tokWhitespace):
				value.WriteByte(' ')
			case n.is(tokString):
				if quotedWithoutEmbeddedQuotes(n.tok.raw) {
					value.WriteString(n.tok.raw)
				}
			case n.kind == nodeFunction:
				if fn, ok := downcaseASCII(n.tok.value); ok && allowedCSSFunctions[fn] {
					p.stringify(&value, n)
				}
			case n.is(tokIdent):
				if keyword := n.tok.value; !shorthand || allowedCSSKeywords[keyword] || cssKeywordish.MatchString(keyword) {
					value.WriteString(keyword)
				}
			case n.kind == nodeBlock:
				// A simple block has no :raw, so it maps to nil and is compacted away.
			default:
				value.WriteString(n.tok.raw)
			}
		}
		v := strings.Trim(value.String(), rubyStripSet)
		if v == "" {
			continue
		}
		if it.important {
			v += " !important"
		}

		// scrub_css re-parses "name:value" and keeps only the first node.
		p2, items2, err := parseProperties(name + ":" + v)
		if err != nil {
			return "", err
		}
		if len(items2) > 0 {
			switch first := items2[0]; first.kind {
			case itemProperty:
				for _, n := range first.decl {
					p2.stringify(&out, n)
				}
			case itemToken:
				out.WriteString(first.tok.raw)
			case itemAtRule:
				return "", ErrUnported
			}
		}
		out.WriteByte(';')
	}
	return out.String(), nil
}

func hasURL(children []*node) bool {
	for _, n := range children {
		if n.is(tokURL) || n.is(tokBadURL) {
			return true
		}
	}
	return false
}

// isShorthand is SHORTHAND_CSS_PROPERTIES.include?(name.split("-").first).
func isShorthand(name string) bool {
	first, _, _ := strings.Cut(name, "-")
	return shorthandCSSProperties[first]
}

// quotedWithoutEmbeddedQuotes is CSS_PROPERTY_STRING_WITHOUT_EMBEDDED_QUOTES,
// /\A(["'])?[^"']+\1\z/, on a string token's raw text, which always opens with a quote. A
// backreference to the skipped group fails in Onigmo, so the closing quote is required.
func quotedWithoutEmbeddedQuotes(raw string) bool {
	n := len(raw)
	return n >= 3 && (raw[0] == '"' || raw[0] == '\'') && raw[n-1] == raw[0] &&
		!strings.ContainsAny(raw[1:n-1], `"'`)
}

// String#strip removes NUL as well as ASCII whitespace, from both ends.
const rubyStripSet = "\x00\t\n\v\f\r "

// downcaseASCII is String#downcase for comparing against ASCII sets: ok is false when the
// result would contain a non-ASCII character. KELVIN SIGN is the only non-ASCII character
// that downcases to ASCII alone (U+0130 gains a combining dot).
func downcaseASCII(s string) (string, bool) {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
			b.WriteByte(byte(r) + 'a' - 'A')
		case r < utf8.RuneSelf:
			b.WriteByte(byte(r))
		case r == '\u212A':
			b.WriteByte('k')
		default:
			return "", false
		}
	}
	return b.String(), true
}

// equalASCIIFold is s.downcase == lower for an all-lowercase ASCII word without a k.
func equalASCIIFold(s, lower string) bool {
	if len(s) != len(lower) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != lower[i] {
			return false
		}
	}
	return true
}

func setOf(words ...string) map[string]bool {
	set := make(map[string]bool, len(words))
	for _, w := range words {
		set[w] = true
	}
	return set
}
