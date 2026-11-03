package rails

import (
	"strings"
	"unicode/utf8"
)

// The first middleware is Rack::UTF8Sanitizer (rack-utf8_sanitizer 1.9.1), so Rails only ever
// sees what these return.

// sanitizeString is its replace strategy: a string that is not valid UTF-8 has every byte
// above 0x7F replaced with U+FFFD, valid multibyte characters included.
func sanitizeString(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] < 0x80 {
			b.WriteByte(s[i])
		} else {
			b.WriteString("\uFFFD")
		}
	}
	return b.String()
}

// sanitizeURIEncoded is sanitize_uri_encoded_string, applied to the path, query string,
// Referer and each cookie: it decodes %XX escapes of unreserved and non-ASCII bytes,
// sanitizes, and re-escapes everything outside RFC 3986's reserved and unreserved sets.
func sanitizeURIEncoded(s string) string {
	decoded := unescapeUnreserved(sanitizeString(s))
	return escapeUnsafe(sanitizeString(decoded))
}

func unescapeUnreserved(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			c := unhex(s[i+1])<<4 | unhex(s[i+2])
			if isUnreserved(c) || c >= 0x80 {
				b.WriteByte(c)
				i += 2
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// escapeUnsafe is URI::DEFAULT_PARSER.escape(input, UNSAFE).
func escapeUnsafe(s string) string {
	const upperHex = "0123456789ABCDEF"
	clean := 0
	for clean < len(s) && isSafe(s[clean]) {
		clean++
	}
	if clean == len(s) {
		return s
	}
	var b strings.Builder
	b.WriteString(s[:clean])
	for i := clean; i < len(s); i++ {
		c := s[i]
		if isSafe(c) {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(upperHex[c>>4])
		b.WriteByte(upperHex[c&15])
	}
	return b.String()
}

func isSafe(c byte) bool {
	return isUnreserved(c) || strings.IndexByte("!*'();/?:@&=+$,[]%", c) >= 0
}

func isUnreserved(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~'
}

func isHex(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func unhex(c byte) byte {
	switch {
	case c >= 'a':
		return c - 'a' + 10
	case c >= 'A':
		return c - 'A' + 10
	}
	return c - '0'
}

// parseCookies is sanitize_cookies, which splits on ; or , and sanitizes each part, then
// Rack::Utils.parse_cookies_header on the rejoined header. A sanitized part holds no ; to
// re-split on, so the parts are parsed as they come. First value wins; a value whose
// escaping is invalid is kept raw; a cookie without "=" is present with a nil value.
func parseCookies(headers []string) map[string]*string {
	cookies := map[string]*string{}
	for _, header := range headers {
		start := 0
		for i := 0; i <= len(header); i++ {
			if i < len(header) && header[i] != ';' && header[i] != ',' {
				continue
			}
			addCookie(cookies, sanitizeURIEncoded(header[start:i]))
			for i+1 < len(header) && header[i+1] == ' ' {
				i++
			}
			start = i + 1
		}
	}
	return cookies
}

func addCookie(cookies map[string]*string, cookie string) {
	if cookie == "" {
		return
	}
	key, value, hasValue := strings.Cut(cookie, "=")
	if _, seen := cookies[key]; seen {
		return
	}
	if !hasValue {
		cookies[key] = nil
		return
	}
	if decoded, ok := DecodeWWWFormComponent(value); ok {
		value = decoded
	}
	cookies[key] = &value
}

// DecodeWWWFormComponent is URI.decode_www_form_component, which rejects a % that does
// not start an escape.
func DecodeWWWFormComponent(s string) (string, bool) {
	if !strings.ContainsAny(s, "%+") {
		return s, true
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '+':
			b.WriteByte(' ')
		case c == '%':
			if i+2 >= len(s) || !isHex(s[i+1]) || !isHex(s[i+2]) {
				return "", false
			}
			b.WriteByte(unhex(s[i+1])<<4 | unhex(s[i+2]))
			i += 2
		default:
			b.WriteByte(c)
		}
	}
	return b.String(), true
}
