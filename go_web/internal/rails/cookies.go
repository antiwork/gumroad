package rails

import (
	"net/http"
	"regexp"
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
	labels := strings.Split(host, ".")
	if ipLikeHost.MatchString(host) || len(labels) == 1 {
		return ""
	}
	for _, l := range labels {
		if l == "" {
			return ""
		}
	}
	n := 2
	if twoPartSuffix.MatchString(host) {
		n = 3
	}
	if n > len(labels) {
		n = len(labels)
	}
	return strings.Join(labels[len(labels)-n:], ".")
}

// CookieLine is Rack::Utils.set_cookie_header with path "/" and Rails' default SameSite
// Lax, then SecureHeaders' flags: Secure when secure, HttpOnly when Rack did not set it.
// maxAge is "" to leave it out.
func CookieLine(name, value, domain, maxAge string, expires time.Time, httpOnly, secure bool) string {
	var b strings.Builder
	b.WriteString(name + "=" + value)
	if domain != "" {
		b.WriteString("; domain=" + domain)
	}
	b.WriteString("; path=/")
	if maxAge != "" {
		b.WriteString("; max-age=" + maxAge)
	}
	b.WriteString("; expires=" + expires.UTC().Format(http.TimeFormat))
	if httpOnly {
		b.WriteString("; httponly")
	}
	b.WriteString("; samesite=lax")
	if secure {
		b.WriteString("; secure")
	}
	if !httpOnly {
		b.WriteString("; HttpOnly")
	}
	return b.String()
}

// DeleteCookieLine is cookies.delete(name, domain:).
func DeleteCookieLine(name, domain string, secure bool) string {
	return CookieLine(name, "", domain, "0", time.Unix(0, 0), false, secure)
}

// AddYears is Time#advance(years:), which clamps Feb 29 to Feb 28.
func AddYears(t time.Time, years int) time.Time {
	t = t.UTC()
	day := t.Day()
	if last := time.Date(t.Year()+years, t.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day(); day > last {
		day = last
	}
	return time.Date(t.Year()+years, t.Month(), day, t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.UTC)
}

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
