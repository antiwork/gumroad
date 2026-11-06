package csssan

import (
	"strings"
	"unicode/utf8"
)

// AllowedURI is Loofah::HTML5::Scrub.allowed_uri?(s). It returns ErrUnported for invalid
// UTF-8 and for entities that decode to a surrogate, where Ruby raises ArgumentError.
func AllowedURI(s string) (bool, error) {
	if !utf8.ValidString(s) {
		return false, ErrUnported
	}
	s = removeControlCharacters(s)
	if strings.IndexByte(s, '&') >= 0 {
		var ok bool
		if s, ok = unescapeHTML(s); !ok {
			return false, ErrUnported
		}
		// Only a decoded reference can bring back a control character.
		s = removeControlCharacters(s)
	}
	s = strings.ReplaceAll(s, "&colon;", ":")

	// URI_PROTOCOL_REGEX can only match up to the first colon. No separator starts with a
	// scheme character, so split(PROTOCOL_SEPARATOR)[0] is the scheme.
	colon := strings.IndexByte(s, ':')
	if colon < 0 {
		return true, nil
	}
	head := downcaseForMatch(s[:colon+1])
	if !uriProtocol.MatchString(head) {
		return true, nil
	}
	protocol := head[:len(head)-1]
	if !allowedProtocols[protocol] {
		return false, nil
	}
	if protocol != "data" {
		return true, nil
	}
	return dataMediatypeAllowed(s[colon+1:]), nil
}

// dataMediatypeAllowed is the data: check on what follows the scheme's colon. Ruby takes
// split(PROTOCOL_SEPARATOR)[1], the text up to the next separator, and then the first field
// of its split(/[;,]/), which is nil (allowed) when the text is only ";" and ",". downcase is
// deferred to the mediatype: it changes no separator.
func dataMediatypeAllowed(rest string) bool {
	end, runes := 0, 0
	for end < len(rest) && rest[end] != ';' && rest[end] != ',' && !separatorAt(rest, end) {
		if utf8.RuneStart(rest[end]) {
			// downcaseForMatch keeps the rune count, and every mediatype is short ASCII.
			if runes++; runes > maxMediatypeLen {
				return false
			}
		}
		end++
	}
	if end > 0 {
		return allowedURIDataMediatypes[downcaseForMatch(rest[:end])]
	}
	for end < len(rest) && (rest[end] == ';' || rest[end] == ',') {
		end++
	}
	return end == len(rest) || separatorAt(rest, end)
}

var maxMediatypeLen = func() int {
	n := 0
	for m := range allowedURIDataMediatypes {
		n = max(n, len(m))
	}
	return n
}()

// separatorAt reports whether SafeList::PROTOCOL_SEPARATOR,
// /:|(&#0*58)|(&#x70)|(&#x0*3a)|(%|&#37;)3A/i, matches at s[i].
func separatorAt(s string, i int) bool {
	switch s[i] {
	case ':':
		return true
	case '%':
		return hasPrefixFold(s[i+1:], "3a")
	case '&':
		ref, ok := strings.CutPrefix(s[i+1:], "#")
		switch {
		case !ok:
			return false
		case hasPrefixFold(ref, "37;3a"), hasPrefixFold(ref, "x70"):
			return true
		case hasPrefixFold(ref, "x"):
			return hasPrefixFold(strings.TrimLeft(ref[1:], "0"), "3a")
		}
		return strings.HasPrefix(strings.TrimLeft(ref, "0"), "58")
	}
	return false
}

func hasPrefixFold(s, lower string) bool {
	return len(s) >= len(lower) && equalASCIIFold(s[:len(lower)], lower)
}

// AllowedAttribute reports whether SafeList::ALLOWED_ATTRIBUTES includes name.
func AllowedAttribute(name string) bool { return allowedAttributes[name] }

// AttrValIsURI reports whether SafeList::ATTR_VAL_IS_URI includes name.
func AttrValIsURI(name string) bool { return attrValIsURI[name] }

// SVGAttrValAllowsRef reports whether SafeList::SVG_ATTR_VAL_ALLOWS_REF includes name.
func SVGAttrValAllowsRef(name string) bool { return svgAttrValAllowsRef[name] }

// removeControlCharacters is gsub(CONTROL_CHARACTERS, ""): /[`\u0000-\u0020\u007f\u0080-\u0101]/.
func removeControlCharacters(s string) string {
	var b strings.Builder
	kept := 0
	for i := 0; i < len(s); {
		n := controlLen(s, i)
		if n == 0 {
			i++
			continue
		}
		if kept == 0 {
			b.Grow(len(s))
		}
		b.WriteString(s[kept:i])
		i += n
		kept = i
	}
	if kept == 0 {
		return s
	}
	b.WriteString(s[kept:])
	return b.String()
}

// controlLen is the byte length of a CONTROL_CHARACTERS match at s[i] in valid UTF-8, or 0:
// U+0080-U+00FF lead with C2 or C3, and U+0100-U+0101 are C4 80 and C4 81.
func controlLen(s string, i int) int {
	switch c := s[i]; {
	case c <= 0x20 || c == '`' || c == 0x7F:
		return 1
	case c == 0xC2 || c == 0xC3 || c == 0xC4 && i+1 < len(s) && s[i+1] <= 0x81:
		return 2
	}
	return 0
}

// unescapeHTML is optimized_unescape_html from Ruby 3.4's cgi/escape: &apos; &amp; &quot;
// &gt; &lt; and numeric references below U+10FFFF, each needing its semicolon. ok is false
// when one decodes to a surrogate, which leaves Ruby a string it cannot match against.
func unescapeHTML(s string) (string, bool) {
	var b strings.Builder
	beg := 0
	for i := strings.IndexByte(s, '&'); i >= 0; {
		next := i + 1
		if decoded, end, ok := htmlReference(s, next); ok {
			if decoded >= 0xD800 && decoded <= 0xDFFF {
				return "", false
			}
			if beg == 0 {
				b.Grow(len(s))
			}
			b.WriteString(s[beg:i])
			b.WriteRune(decoded)
			beg, next = end, end
		}
		j := strings.IndexByte(s[next:], '&')
		if j < 0 {
			break
		}
		i = next + j
	}
	if beg == 0 {
		return s, true
	}
	b.WriteString(s[beg:])
	return b.String(), true
}

var namedReferences = []struct {
	name string
	char rune
}{{"apos;", '\''}, {"amp;", '&'}, {"quot;", '"'}, {"gt;", '>'}, {"lt;", '<'}}

// htmlReference decodes the reference starting at s[i], just after an "&", and returns the
// index past its semicolon.
func htmlReference(s string, i int) (rune, int, bool) {
	for _, ref := range namedReferences {
		if strings.HasPrefix(s[i:], ref.name) {
			return ref.char, i + len(ref.name), true
		}
	}
	if i >= len(s) || s[i] != '#' {
		return 0, 0, false
	}
	i++
	base := 10
	switch {
	case len(s)-i >= 2 && isDigitByte(s[i]):
	case i < len(s) && (s[i] == 'x' || s[i] == 'X') && len(s)-i-1 >= 2 && isHexByte(s[i+1]):
		i++
		base = 16
	default:
		return 0, 0, false
	}
	const charLimit = 0x10FFFF
	cc := 0
	for ; i < len(s) && digitValue(s[i]) < base; i++ {
		// Saturate: anything at the limit fails, and ruby_scan_digits flags overflow anyway.
		cc = min(cc*base+digitValue(s[i]), charLimit)
	}
	if cc >= charLimit || i >= len(s) || s[i] != ';' {
		return 0, 0, false
	}
	return rune(cc), i + 1, true
}

func isDigitByte(c byte) bool { return c >= '0' && c <= '9' }
func isHexByte(c byte) bool   { return digitValue(c) < 16 }

func digitValue(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'z':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'Z':
		return int(c-'A') + 10
	}
	return 36
}

// downcaseForMatch stands in for String#downcase before ASCII-only matching: only ASCII
// and KELVIN SIGN downcase to ASCII alone, so every other character is left as it is.
func downcaseForMatch(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'A' && r <= 'Z':
			return r + 'a' - 'A'
		case r == '\u212A':
			return 'k'
		}
		return r
	}, s)
}
