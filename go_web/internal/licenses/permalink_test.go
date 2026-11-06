package licenses

import "testing"

func TestPermalinksCompareAsStringDowncase(t *testing.T) {
	for _, c := range []struct {
		a, b string
		same bool
	}{{"AbC", "abc", true}, {"Key", "key", true}, {"ſale", "sale", false}, {"x", "y", false}} {
		if got := sameDowncase(c.a, c.b); got != c.same {
			t.Errorf("sameDowncase(%q, %q) = %v", c.a, c.b, got)
		}
	}
}
