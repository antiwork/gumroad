package web

import "strings"

// CDNMap is CDN_URL_MAP: storage origins, in the map's order, and the CDN prefixes that front them.
type CDNMap [][2]string

// URLFor is cdn_url_for: each origin in url replaced by its CDN prefix.
func (m CDNMap) URLFor(url string) string {
	for _, pair := range m {
		url = strings.ReplaceAll(url, pair[0], pair[1])
	}
	return url
}
