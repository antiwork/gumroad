package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Helpers that reproduce the Ruby semantics the ported Rails code relies on.

// Ruby's ISSPACE, which unlike Go's \s includes \v.
const rubySpace = " \t\n\v\f\r"

// blank mirrors ActiveSupport's String#blank? for ASCII input.
func blank[T string | []byte](s T) bool {
	for i := 0; i < len(s); i++ {
		if strings.IndexByte(rubySpace, s[i]) < 0 {
			return false
		}
	}
	return true
}

// rubyToI mirrors String#to_i: optional leading whitespace and sign, then the
// longest run of digits (single underscores allowed between them), else 0.
func rubyToI(s string) int64 {
	s = strings.TrimLeft(s, rubySpace)
	sign := int64(1)
	if s != "" && (s[0] == '+' || s[0] == '-') {
		if s[0] == '-' {
			sign = -1
		}
		s = s[1:]
	}
	var digits strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			digits.WriteByte(c)
			continue
		}
		if c == '_' && digits.Len() > 0 && i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' {
			continue
		}
		break
	}
	n, err := strconv.ParseInt(digits.String(), 10, 64)
	if err != nil {
		return 0
	}
	return sign * n
}

var rubyFloatPrefix = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:_[0-9]+)*)?(?:\.[0-9]+(?:_[0-9]+)*)?(?:[eE][+-]?[0-9]+)?`)

// rubyToF mirrors String#to_f for decimal input: the longest leading float, else 0.
func rubyToF(s string) float64 {
	match := rubyFloatPrefix.FindString(strings.TrimLeft(s, rubySpace))
	f, _ := strconv.ParseFloat(strings.ReplaceAll(match, "_", ""), 64)
	return f
}

// rubyInteger mirrors Kernel#Integer on a String: surrounding whitespace, one sign, a
// 0x/0b/0o/0d prefix or a leading 0 for octal, and single underscores between digits.
// Values outside int64 are refused; Ruby would make a Bignum.
func rubyInteger(s string) (int64, bool) {
	if strings.IndexByte(s, 0) >= 0 {
		return 0, false
	}
	s = strings.Trim(s, rubySpace)
	sign := ""
	if s != "" && (s[0] == '+' || s[0] == '-') {
		sign, s = s[:1], s[1:]
	}
	base := 10
	if len(s) > 1 && s[0] == '0' {
		switch s[1] {
		case 'x', 'X':
			base, s = 16, s[2:]
		case 'b', 'B':
			base, s = 2, s[2:]
		case 'o', 'O':
			base, s = 8, s[2:]
		case 'd', 'D':
			base, s = 10, s[2:]
		default:
			base = 8
		}
	}
	if s == "" || s[0] == '_' || s[0] == '+' || s[0] == '-' || s[len(s)-1] == '_' || strings.Contains(s, "__") {
		return 0, false
	}
	n, err := strconv.ParseInt(sign+strings.ReplaceAll(s, "_", ""), base, 64)
	return n, err == nil
}

// rubySplit mirrors String#split with a string separator: trailing empty fields are dropped.
func rubySplit(s, sep string) []string {
	parts := strings.Split(s, sep)
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// strictDecode64 mirrors Base64.strict_decode64, which rejects the line breaks Go's
// decoder would skip.
func strictDecode64(s string) ([]byte, error) {
	if strings.ContainsAny(s, "\r\n") {
		return nil, errors.New("line break in base64")
	}
	return base64.StdEncoding.Strict().DecodeString(s)
}

func isBase64Alphabet(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/'
}

// rubyDecode64 mirrors Base64.decode64 (pack.c's lenient "m"): characters outside the
// alphabet are skipped, a '=' in a group's third or fourth place ends the data, and a
// lone trailing character is dropped.
func rubyDecode64(s string) []byte {
	kept := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case isBase64Alphabet(c):
			kept = append(kept, c)
		case c == '=' && len(kept)%4 >= 2:
			i = len(s)
		}
	}
	if len(kept)%4 == 1 {
		kept = kept[:len(kept)-1]
	}
	out := make([]byte, base64.RawStdEncoding.DecodedLen(len(kept)))
	n, _ := base64.RawStdEncoding.Decode(out, kept)
	return out[:n]
}

// rubyExtname mirrors File.extname: trailing slashes are ignored, leading dots of the
// last component don't start an extension, and a final dot alone is ".".
func rubyExtname(path string) string {
	name := strings.TrimRight(path, "/")
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	name = strings.TrimLeft(name, ".")
	if i := strings.LastIndexByte(name, '.'); i >= 0 {
		return name[i:]
	}
	return ""
}

// URI::RFC3986_Parser's grammar (uri 1.1.1), with its subroutine calls expanded. Its
// possessive quantifiers never change what matches here, because each one is followed
// by a character its class excludes.
var (
	rfc3986URI, rfc3986RelativeRef *regexp.Regexp
	invalidQueryEscape             = regexp.MustCompile(`%[^0-9A-Fa-f][^0-9A-Fa-f]`)
	// URI::Generic#query= deletes these before checking escapes.
	queryLineBreaks = strings.NewReplacer("\t", "", "\r", "", "\n", "")
)

func init() {
	const (
		hex     = `[0-9A-Fa-f]`
		h16     = hex + `{1,4}`
		dec     = `(?:[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]|[0-9])`
		ipv4    = dec + `\.` + dec + `\.` + dec + `\.` + dec
		ls32    = `(?:` + h16 + `:` + h16 + `|` + ipv4 + `)`
		ipv6    = `(?:(?:` + h16 + `:){6}` + ls32 + `|::(?:` + h16 + `:){5}` + ls32 + `|` + h16 + `::(?:` + h16 + `:){4}` + ls32 + `|(?:(?:` + h16 + `:)?` + h16 + `)?::(?:` + h16 + `:){3}` + ls32 + `|(?:(?:` + h16 + `:){0,2}` + h16 + `)?::(?:` + h16 + `:){2}` + ls32 + `|(?:(?:` + h16 + `:){0,3}` + h16 + `)?::` + h16 + `:` + ls32 + `|(?:(?:` + h16 + `:){0,4}` + h16 + `)?::` + ls32 + `|(?:(?:` + h16 + `:){0,5}` + h16 + `)?::` + h16 + `|(?:(?:` + h16 + `:){0,6}` + h16 + `)?::)`
		host    = `(?:\[(?:` + ipv6 + `|v` + hex + `+\.[!$&-.0-9:;=A-Z_a-z~]+)\]|` + ipv4 + `|(?:%` + hex + hex + `|[!$&-.0-9;=A-Z_a-z~])*)`
		user    = `(?:%` + hex + hex + `|[!$&-.0-9:;=A-Z_a-z~])*`
		seg     = `(?:%` + hex + hex + `|[!$&-.0-9:;=@A-Z_a-z~/])`
		segNS   = `(?:%` + hex + hex + `|[!$&-.0-9:;=@A-Z_a-z~])`
		segNC   = `(?:%` + hex + hex + `|[!$&-.0-9;=@A-Z_a-z~])`
		tail    = `(?:\?(?P<query>[^#]*))?(?:#(?:%` + hex + hex + `|[!$&-.0-9:;=@A-Z_a-z~/?])*)?\z`
		authAbs = `//(?:` + user + `@)?(?P<host>` + host + `)(?::(?P<port>[0-9]*))?(?P<abempty>(?:/` + seg + `*)?)`
		authRel = `//(?:` + user + `@)?(?P<host>` + host + `)?(?::(?P<port>[0-9]*))?(?P<abempty>(?:/` + seg + `*)?)`
	)
	rfc3986URI = regexp.MustCompile(`\A(?P<scheme>[A-Za-z][+\-.0-9A-Za-z]*):(?:` + authAbs +
		`|(?P<absolute>/(?:` + segNS + seg + `*)?)|(?P<rootless>` + segNS + seg + `*)|(?P<empty>))` + tail)
	rfc3986RelativeRef = regexp.MustCompile(`\A(?:` + authRel +
		`|(?P<absolute>/` + seg + `*)|(?P<noscheme>` + segNC + `+(?:/` + seg + `*)?)|(?P<empty>))` + tail)
}

// rubyURI is what Aws::SNS::MessageVerifier reads from a URI.parse result.
type rubyURI struct {
	scheme, host, port, path string
	query                    *string // after URI::Generic#query= escaping
	hasHost                  bool
}

var errInvalidURI = errors.New("URI::InvalidURIError")

// rubyParseURI mirrors URI.parse (uri 1.1.1's RFC 3986 parser and URI::Generic's
// setters): an error is URI::InvalidURIError, which the verifier doesn't rescue.
func rubyParseURI(s string) (rubyURI, error) {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return rubyURI{}, errInvalidURI
		}
	}
	re := rfc3986URI
	m := re.FindStringSubmatchIndex(s)
	if m == nil {
		re = rfc3986RelativeRef
		if m = re.FindStringSubmatchIndex(s); m == nil {
			return rubyURI{}, errInvalidURI
		}
	}
	group := func(name string) (string, bool) {
		i := re.SubexpIndex(name)
		if i < 0 || m[2*i] < 0 {
			return "", false
		}
		return s[m[2*i]:m[2*i+1]], true
	}
	var u rubyURI
	if scheme, ok := group("scheme"); ok {
		u.scheme = strings.ToLower(scheme)
	}
	if _, opaque := group("rootless"); opaque {
		// An opaque URI carries its query inside the opaque part, unchecked.
		return u, nil
	}
	u.host, u.hasHost = group("host")
	u.port, _ = group("port")
	for _, name := range []string{"abempty", "absolute", "noscheme", "empty"} {
		if path, ok := group(name); ok {
			u.path = path
			break
		}
	}
	if query, ok := group("query"); ok {
		query = queryLineBreaks.Replace(query)
		if invalidQueryEscape.MatchString(query) {
			return rubyURI{}, errInvalidURI
		}
		var escaped strings.Builder
		for i := 0; i < len(query); i++ {
			if c := query[i]; c == '!' || (c >= '$' && c <= '&') || (c >= '(' && c <= ';') || c == '=' || (c >= '?' && c <= '_') || (c >= 'a' && c <= '~') {
				escaped.WriteByte(c)
			} else {
				fmt.Fprintf(&escaped, "%%%02X", c)
			}
		}
		q := escaped.String()
		u.query = &q
	}
	return u, nil
}
