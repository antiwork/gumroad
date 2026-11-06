package html4

import "strings"

// EscapeText is how a text node serializes outside script and style.
func EscapeText(s string) string {
	var b strings.Builder
	escape(&b, s)
	return b.String()
}
