package web

import (
	"regexp"
	"strings"
)

// SubdomainRequestPattern is Subdomain.subdomain_request?'s pattern, which leaves root's dots
// unescaped. request.host has no port, so root's is dropped.
func SubdomainRequestPattern(root string) *regexp.Regexp {
	root, _, _ = strings.Cut(root, ":")
	return regexp.MustCompile(`\A[a-z0-9-]+.` + root + `\z`)
}
