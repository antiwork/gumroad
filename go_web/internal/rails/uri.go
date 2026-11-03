package rails

import (
	"net/netip"
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

// URIHost is URI.parse(s).host under Ruby 3.4's RFC3986 parser: ok is false where parse
// raises InvalidURIError, and host is "" where the URI has no authority.
func URIHost(s string) (string, bool) {
	if i := schemeEnd(s); i > 0 {
		if host, ok := parseHierPart(s[i+1:], true); ok {
			return host, true
		}
	}
	return parseHierPart(s, false)
}

// schemeEnd returns the index of the colon after a valid scheme, or -1.
func schemeEnd(s string) int {
	if s == "" || !isAlpha(s[0]) {
		return -1
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		switch {
		case c == ':':
			return i
		case isAlpha(c) || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.':
		default:
			return -1
		}
	}
	return -1
}

// parseHierPart matches hier-part (absolute) or relative-part, then the query and
// fragment, and returns the authority's host.
func parseHierPart(s string, absolute bool) (string, bool) {
	rest, fragment, hasFragment := strings.Cut(s, "#")
	if hasFragment && !allChars(fragment, isFragmentChar) {
		return "", false
	}
	path, _, _ := strings.Cut(rest, "?")

	if strings.HasPrefix(path, "//") {
		authority := path[2:]
		if i := strings.IndexByte(authority, '/'); i >= 0 {
			if !allChars(authority[i:], isSegChar) {
				return "", false
			}
			authority = authority[:i]
		}
		return parseAuthority(authority)
	}
	switch {
	case path == "":
		return "", true
	case strings.HasPrefix(path, "/"):
		return "", allChars(path, isSegChar)
	case absolute:
		return "", allChars(path, isSegChar)
	}
	// path-noscheme: the first segment has no colon.
	first, after, _ := strings.Cut(path, "/")
	return "", first != "" && allChars(first, isSegNCChar) && allChars(after, isSegChar)
}

func parseAuthority(authority string) (string, bool) {
	if at := strings.LastIndexByte(authority, '@'); at >= 0 {
		if !allChars(authority[:at], isUserinfoChar) {
			return "", false
		}
		authority = authority[at+1:]
	}
	host, port := authority, ""
	if strings.HasPrefix(authority, "[") {
		end := strings.IndexByte(authority, ']')
		if end < 0 || !validIPLiteral(authority[1:end]) {
			return "", false
		}
		host, port = authority[:end+1], authority[end+1:]
	} else if i := strings.IndexByte(authority, ':'); i >= 0 {
		host, port = authority[:i], authority[i:]
	}
	if port != "" && (port[0] != ':' || !allChars(port[1:], func(c byte) bool { return c >= '0' && c <= '9' })) {
		return "", false
	}
	if !strings.HasPrefix(host, "[") && !validRegName(host) {
		return "", false
	}
	return host, true
}

func validRegName(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' {
			if i+2 >= len(s) || !isHex(s[i+1]) || !isHex(s[i+2]) {
				return false
			}
			i += 2
			continue
		}
		if !isRegNameChar(s[i]) {
			return false
		}
	}
	return true
}

func validIPLiteral(s string) bool {
	if strings.HasPrefix(s, "v") || strings.HasPrefix(s, "V") {
		version, rest, ok := strings.Cut(s[1:], ".")
		return ok && version != "" && allChars(version, isHex) && rest != "" && allChars(rest, isUserinfoChar)
	}
	addr, err := netip.ParseAddr(s)
	return err == nil && addr.Is6() && addr.Zone() == ""
}

func allChars(s string, ok func(byte) bool) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			i += 2
			continue
		}
		if !ok(s[i]) {
			return false
		}
	}
	return true
}

func isAlpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// The character classes are [!$&-.0-9;=A-Z_a-z~] and its variants: &-. is the range & to .
func isRegNameChar(c byte) bool {
	return c == '!' || c == '$' || c >= '&' && c <= '.' || c >= '0' && c <= '9' || c == ';' || c == '=' ||
		isAlpha(c) || c == '_' || c == '~'
}

func isUserinfoChar(c byte) bool { return isRegNameChar(c) || c == ':' }
func isSegNCChar(c byte) bool    { return isRegNameChar(c) || c == '@' }
func isSegChar(c byte) bool      { return isSegNCChar(c) || c == ':' || c == '/' }
func isFragmentChar(c byte) bool { return isSegChar(c) || c == '?' }
