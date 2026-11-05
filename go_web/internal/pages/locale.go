// Package pages is what InertiaRendering and RenderingExtension share with every Inertia
// page: the shared props, and the layout config they render into.
package pages

import (
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// rubySortStableUpTo is how many languages Array#sort orders like a stable sort on every
// platform. Ruby sorts with the C library's qsort_r: glibc 2.36's merge sort is stable, but
// BSD's and newer glibc introsorts reorder ties past insertion sort's small lists.
const rubySortStableUpTo = 6

// Locale is RenderingExtension's locale: http_accept_language 2.1.1's
// user_preferred_languages[0] || "en-US". ok is false when only Ruby can be sure of the
// answer: more than six languages with tied qualities, non-ASCII, or a quality whose to_f
// isn't plain.
func Locale(header string) (locale string, ok bool) {
	if strings.ContainsAny(header, rails.RubySpace) {
		header = strings.Map(func(r rune) rune {
			if strings.ContainsRune(rails.RubySpace, r) {
				return -1
			}
			return r
		}, header)
	}
	if header == "" {
		return "en-US", true
	}
	for i := 0; i < len(header); i++ {
		if header[i] >= 0x80 {
			return "", false
		}
	}
	type language struct {
		locale  string
		quality float64
	}
	var languages []language
	for _, part := range rails.Split(header, ",") {
		pieces := rails.Split(part, ";q=")
		if len(pieces) == 0 || !localePrefix(pieces[0]) {
			// The parser rescues its ArgumentError with [].
			return "en-US", true
		}
		q := 1.0
		if len(pieces) > 1 {
			var exact bool
			if q, exact = rails.StringToF(pieces[1]); !exact {
				return "", false
			}
		}
		languages = append(languages, language{locale: canonical(pieces[0]), quality: q})
	}
	if len(languages) > rubySortStableUpTo {
		seen := map[float64]bool{}
		for _, l := range languages {
			if seen[l.quality] {
				return "", false
			}
			seen[l.quality] = true
		}
	}
	// A stable sort by quality, then the first that isn't the wildcard: the earliest of the
	// highest quality.
	best := -1
	for i, l := range languages {
		if l.locale != "*" && (best < 0 || l.quality > languages[best].quality) {
			best = i
		}
	}
	if best < 0 {
		return "en-US", true
	}
	return languages[best].locale, true
}

// localePrefix is the parser's /^[a-z\-0-9]+|\*$/i on ASCII without line breaks.
func localePrefix(s string) bool {
	if s == "" {
		return false
	}
	c := s[0] | 0x20
	return c >= 'a' && c <= 'z' || s[0] >= '0' && s[0] <= '9' || s[0] == '-' || s[len(s)-1] == '*'
}

// canonical is locale.downcase.gsub(/-[a-z0-9]+$/i, &:upcase): a trailing territory after the
// last dash is uppercased.
func canonical(s string) string {
	s = strings.ToLower(s)
	i := strings.LastIndexByte(s, '-')
	if i < 0 || i == len(s)-1 {
		return s
	}
	for j := i + 1; j < len(s); j++ {
		if c := s[j]; !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return s
		}
	}
	return s[:i] + strings.ToUpper(s[i:])
}
