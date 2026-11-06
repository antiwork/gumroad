package web

import (
	"regexp"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// CustomDomainNames are the custom_domains.domain values CustomDomain.find_by_host reads for
// host, in its order: the apex then www for an apex or www host, else the host itself. None for
// a host this suffix list rejects, which an IP is though PublicSuffix parses one. ok is false
// off the ICANN section, where this list and the gem's older one can part.
func CustomDomainNames(host string) (names []string, ok bool) {
	name := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	if name == "" || strings.HasPrefix(name, ".") || strings.Contains(name, "://") {
		return nil, true
	}
	registrable, err := publicsuffix.EffectiveTLDPlusOne(name)
	if err != nil {
		return nil, true
	}
	_, icann := publicsuffix.PublicSuffix(name)
	if trd := strings.TrimSuffix(strings.TrimSuffix(name, registrable), "."); trd == "" || trd == "www" {
		return []string{registrable, "www." + registrable}, icann
	}
	return []string{host}, icann
}

// SubdomainRequestPattern is Subdomain.subdomain_request?'s pattern, which leaves root's dots
// unescaped. request.host has no port, so root's is dropped.
func SubdomainRequestPattern(root string) *regexp.Regexp {
	root, _, _ = strings.Cut(root, ":")
	return regexp.MustCompile(`\A[a-z0-9-]+.` + root + `\z`)
}
