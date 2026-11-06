package rails

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

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

// URI is what callers read from a URI.parse result. Scheme is downcased.
type URI struct {
	Scheme, Host, Port, Path string
	Query                    *string // after URI::Generic#query= escaping
	HasHost                  bool
}

// ErrInvalidURI is URI::InvalidURIError.
var ErrInvalidURI = errors.New("URI::InvalidURIError")

// ParseURI mirrors URI.parse (uri 1.1.1's RFC 3986 parser and URI::Generic's setters).
// URI.for's scheme classes (FTP, MAILTO, LDAP, FILE, and GID once globalid loads) can
// still rewrite or reject what this returns for their schemes.
func ParseURI(s string) (URI, error) {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return URI{}, ErrInvalidURI
		}
	}
	re := rfc3986URI
	m := re.FindStringSubmatchIndex(s)
	if m == nil {
		re = rfc3986RelativeRef
		if m = re.FindStringSubmatchIndex(s); m == nil {
			return URI{}, ErrInvalidURI
		}
	}
	group := func(name string) (string, bool) {
		i := re.SubexpIndex(name)
		if i < 0 || m[2*i] < 0 {
			return "", false
		}
		return s[m[2*i]:m[2*i+1]], true
	}
	var u URI
	if scheme, ok := group("scheme"); ok {
		u.Scheme = strings.ToLower(scheme)
	}
	if _, opaque := group("rootless"); opaque {
		// An opaque URI carries its query inside the opaque part, unchecked.
		return u, nil
	}
	u.Host, u.HasHost = group("host")
	if hostAt := m[2*re.SubexpIndex("host")]; re == rfc3986RelativeRef && u.Host == "" && hostAt > 0 && s[hostAt-1] == '/' {
		// The relative host group ends in (?<!/), so an empty host right after "//" is nil.
		u.HasHost = false
	}
	u.Port, _ = group("port")
	for _, name := range []string{"abempty", "absolute", "noscheme", "empty"} {
		if path, ok := group(name); ok {
			u.Path = path
			break
		}
	}
	if query, ok := group("query"); ok {
		query = queryLineBreaks.Replace(query)
		if invalidQueryEscape.MatchString(query) {
			return URI{}, ErrInvalidURI
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
		u.Query = &q
	}
	return u, nil
}
