package web

import (
	"fmt"
	"strings"
)

// EscapeSegment is Journey's escape_segment, which route helpers apply to each path
// segment: everything but unreserved characters, sub-delims, : and @ as uppercase %XX.
func EscapeSegment(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
			strings.IndexByte("-._~!$&'()*+,;=:@", c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// withoutDefaultPort is what url_for leaves of a host: no port when it is the protocol's.
func (e *Environment) withoutDefaultPort(host string) string {
	if (e.Protocol == "https" && strings.HasSuffix(host, ":443")) || (e.Protocol == "http" && strings.HasSuffix(host, ":80")) {
		return host[:strings.LastIndexByte(host, ':')]
	}
	return host
}

// ProductLongURL is Link#long_url: short_link_url for the permalink on the seller's
// subdomain, from User#username (the username column, else the external id); on the app's
// domain when that is blank.
func (e *Environment) ProductLongURL(username, permalink string) string {
	host := e.Protocol + "://" + e.withoutDefaultPort(e.Domain)
	if strings.TrimSpace(username) != "" {
		host = e.Protocol + "://" + strings.ReplaceAll(username, "_", "-") + "." + e.withoutDefaultPort(e.RootDomain)
	}
	return host + "/l/" + EscapeSegment(permalink)
}
