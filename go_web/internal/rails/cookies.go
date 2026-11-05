package rails

import (
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"
)

var (
	ipLikeHost    = regexp.MustCompile(`^[\d.]+$`)
	twoPartSuffix = regexp.MustCompile(`\.[^.]{2,3}\.[^.]{2}\z`)
)

// CookieDomainAll is CookieJar#handle_options for domain: :all without a tld_length: the
// last two labels, three for co.uk-style suffixes, none for IPs and single labels.
func CookieDomainAll(host string) string {
	if twoPartSuffix.MatchString(host) {
		return CookieDomainTLD(host, 3)
	}
	return CookieDomainTLD(host, 2)
}

// CookieLine is a SetCookie with an optional max-age, for the cookies beacons write.
func CookieLine(name, value, domain, maxAge string, expires time.Time, httpOnly, secure bool) string {
	return SetCookie{Name: name, Value: value, Domain: domain, MaxAge: maxAge, Expires: expires, HTTPOnly: httpOnly}.Line(secure)
}

// DeleteCookieLine is cookies.delete(name, domain:).
func DeleteCookieLine(name, domain string, secure bool) string {
	return CookieLine(name, "", domain, "0", time.Unix(0, 0), false, secure)
}

// AddYears is Time#advance(years:), which ActiveSupport does as months.
func AddYears(t time.Time, years int) time.Time { return AddMonths(t, 12*years) }

// SecureCookies is SecureHeaders' Secure flag: only where PROTOCOL is https, and only for
// requests its middleware sees as HTTPS (the first X-Forwarded-Proto entry).
func SecureCookies(protocol string, r *http.Request) bool {
	if protocol != "https" {
		return false
	}
	if r.TLS != nil || r.Header.Get("X-Ssl-Request") == "on" {
		return true
	}
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		first, _, _ := strings.Cut(proto, ",")
		return first == "https"
	}
	return false
}

// SetCookie is a cookie as Rack::Utils.set_cookie_header writes it. Expires is left out
// when zero.
type SetCookie struct {
	Name, Value, Domain string
	// MaxAge is "" to leave it out.
	MaxAge           string
	Expires          time.Time
	Secure, HTTPOnly bool
}

// Line writes the attributes in Rack's order, then appends SecureHeaders' Secure (when
// secure) and HttpOnly flags where Rack left them out.
func (c SetCookie) Line(secure bool) string {
	var b strings.Builder
	b.Grow(len(c.Name) + len(c.Value)*5/4 + 128)
	b.WriteString(RackEscape(c.Name))
	b.WriteByte('=')
	b.WriteString(RackEscape(c.Value))
	if c.Domain != "" {
		b.WriteString("; domain=" + c.Domain)
	}
	b.WriteString("; path=/")
	if c.MaxAge != "" {
		b.WriteString("; max-age=" + c.MaxAge)
	}
	if !c.Expires.IsZero() {
		b.WriteString("; expires=" + c.Expires.UTC().Format(http.TimeFormat))
	}
	if c.Secure {
		b.WriteString("; secure")
	}
	if c.HTTPOnly {
		b.WriteString("; httponly")
	}
	b.WriteString("; samesite=lax")
	if secure && !c.Secure {
		b.WriteString("; secure")
	}
	if !c.HTTPOnly {
		b.WriteString("; HttpOnly")
	}
	return b.String()
}

// CookieDomainTLD is CookieJar#handle_options for domain: :all with a tld_length: the last
// tldLength labels, whatever they are, and no domain for a host with fewer.
func CookieDomainTLD(host string, tldLength int) string {
	labels := strings.Split(host, ".")
	if ipLikeHost.MatchString(host) || len(labels) == 1 || len(labels) < tldLength || slices.Contains(labels, "") {
		return ""
	}
	// Rails would copy any Host header into the attribute; one that isn't a hostname gets
	// no domain here rather than a way to inject attributes.
	if strings.IndexFunc(host, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '.' || r == '_')
	}) >= 0 {
		return ""
	}
	return strings.Join(labels[len(labels)-tldLength:], ".")
}

// RackEscape is Rack::Utils.escape, URI.encode_www_form_component.
func RackEscape(s string) string {
	return formEscape(s, func(c byte) bool {
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '*' || c == '-' || c == '.' || c == '_'
	})
}

// formEscape writes the bytes keep doesn't accept as %XX, and space as +.
func formEscape(s string, keep func(byte) bool) string {
	const upperHex = "0123456789ABCDEF"
	var b strings.Builder
	b.Grow(len(s) + len(s)/4)
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case keep(c):
			b.WriteByte(c)
		case c == ' ':
			b.WriteByte('+')
		default:
			b.WriteByte('%')
			b.WriteByte(upperHex[c>>4])
			b.WriteByte(upperHex[c&0xf])
		}
	}
	return b.String()
}

// AddMonths is Time#advance(months:), which clamps the day to the target month's last.
func AddMonths(t time.Time, months int) time.Time {
	t = t.UTC()
	day := t.Day()
	if last := time.Date(t.Year(), t.Month()+time.Month(months)+1, 0, 0, 0, 0, 0, time.UTC).Day(); day > last {
		day = last
	}
	return time.Date(t.Year(), t.Month()+time.Month(months), day, t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.UTC)
}
