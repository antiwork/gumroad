package products

import "testing"

// Ruby 3.4's upcase on each; nothing for one with a letter outside ASCII.
func TestFileTypeUpcase(t *testing.T) {
	for in, want := range map[string]any{
		"pdf\u201d": "PDF\u201d",
		"mp4 (1)":   "MP4 (1)",
		"\u2122\u20ac\u2192\U0001f600\u00b2\u00bd\u00a0": "\u2122\u20ac\u2192\U0001f600\u00b2\u00bd\u00a0",
		"\u24d0":   nil,
		"\u2172":   nil,
		"\u0345":   nil,
		"\u00df":   nil,
		"mp\u00e9": nil,
	} {
		got, ok := fileTypeUpcase(in)
		if want == nil && ok || want != nil && (!ok || got != want) {
			t.Errorf("%+q: %+q %v, want %+q", in, got, ok, want)
		}
	}
}
