package rails

import (
	"sort"
	"strings"
)

// URIUnescape is URI::RFC2396_PARSER.unescape: every %XX, valid UTF-8 or not.
func URIUnescape(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			b.WriteByte(unhex(s[i+1])<<4 | unhex(s[i+2]))
			i += 2
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// URIHost is URI.parse(s).host: ok is false where parse raises InvalidURIError, and host is
// "" where the URI has no authority.
func URIHost(s string) (string, bool) {
	u, err := ParseURI(s)
	if err != nil {
		return "", false
	}
	return u.Host, true
}

// CGIEscape is CGI.escape: everything but ASCII letters, digits, _ . - and ~ as %XX, and
// space as +.
func CGIEscape(s string) string { return formEscape(s, isUnreserved) }

// ToQuery is Hash#to_query for string values: CGI-escaped pairs, sorted, joined by &.
func ToQuery(pairs ...[2]string) string {
	parts := make([]string, len(pairs))
	for i, p := range pairs {
		parts[i] = CGIEscape(p[0]) + "=" + CGIEscape(p[1])
	}
	sort.Strings(parts)
	return strings.Join(parts, "&")
}
