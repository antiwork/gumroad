package beacons

import (
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	directReferrer = "direct"
	// REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS.
	recommendedReferrerDomain = "recommended_by_gumroad"
	// Events#create_event and create_product_page_view keep referrer[0..190].
	maxReferrerLength = 191
)

// referrerDomain is Referrer.extract_domain (lib/utilities/referrer.rb).
func referrerDomain(url *string) string {
	if url == nil || rails.Blank(*url) || *url == directReferrer {
		return directReferrer
	}
	s := rails.URIUnescape(*url)
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		// encode!("UTF-8", "binary", ...) drops every non-ASCII byte; gsub(/\s+/) the spaces.
		if c := s[i]; c < 0x80 && c != ' ' && (c < '\t' || c > '\r') {
			b.WriteByte(c)
		}
	}
	host, ok := rails.URIHost(b.String())
	if !ok || host == "" {
		return directReferrer
	}
	if host = strings.TrimPrefix(strings.ToLower(host), "www."); host == "" {
		return directReferrer
	}
	return host
}
