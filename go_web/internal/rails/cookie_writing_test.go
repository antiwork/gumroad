package rails

import (
	"slices"
	"strings"
	"testing"
	"time"
)

type cookieWriting struct {
	Lines     map[string][]string
	Escape    map[string]string
	CGIEscape map[string]string `json:"cgi_escape"`
	ToQuery   []struct {
		Pairs [][2]string
		Query string
	} `json:"to_query"`
	Months []struct {
		From      time.Time
		PlusMonth time.Time `json:"plus_month"`
	}
}

func TestSetCookieLinesMatchRack(t *testing.T) {
	var fixtures cookieWriting
	loadFixture(t, "cookie_writing.json", &fixtures)
	for host, lines := range fixtures.Lines {
		got := []string{
			SetCookie{Name: "XSRF-TOKEN", Value: "a+b/c="}.Line(true),
			SetCookie{Name: "tld", Value: "v", Domain: CookieDomainTLD(host, 2)}.Line(true),
			SetCookie{Name: "tld3", Value: "v", Domain: CookieDomainTLD(host, 3)}.Line(true),
		}
		if !slices.Equal(got, lines) {
			t.Errorf("%s:\n got %q\nwant %q", host, got, lines)
		}
	}
}

func TestRackEscapeMatchesRack(t *testing.T) {
	var fixtures cookieWriting
	loadFixture(t, "cookie_writing.json", &fixtures)
	for in, want := range fixtures.Escape {
		if got := RackEscape(in); got != want {
			t.Errorf("RackEscape(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAddMonthsMatchesActiveSupport(t *testing.T) {
	var fixtures cookieWriting
	loadFixture(t, "cookie_writing.json", &fixtures)
	for _, c := range fixtures.Months {
		if got := AddMonths(c.From, 1); !got.Equal(c.PlusMonth) {
			t.Errorf("AddMonths(%s) = %s, want %s", c.From, got, c.PlusMonth)
		}
	}
}

func TestHashDeleteKeepsTheOtherKeysInOrder(t *testing.T) {
	h := NewHash()
	for _, k := range []string{"a", "b", "c"} {
		h.Set(k, k)
	}
	h.Delete("b")
	h.Delete("missing")
	h.Set("b", "again")
	if got := EncodeJSON(h); got != `{"a":"a","c":"c","b":"again"}` {
		t.Errorf("got %s", got)
	}
}

func TestCGIEscapeAndToQueryMatchRuby(t *testing.T) {
	var fixtures cookieWriting
	loadFixture(t, "cookie_writing.json", &fixtures)
	for in, want := range fixtures.CGIEscape {
		if got := CGIEscape(in); got != want {
			t.Errorf("CGIEscape(%q) = %q, want %q", in, got, want)
		}
	}
	for _, c := range fixtures.ToQuery {
		if got := ToQuery(c.Pairs...); got != c.Query {
			t.Errorf("ToQuery(%v) = %q, want %q", c.Pairs, got, c.Query)
		}
	}
	if len(fixtures.CGIEscape) == 0 || len(fixtures.ToQuery) == 0 {
		t.Fatal("no fixtures")
	}
}

func TestFullPathAddsTheQueryWhenThereIsOne(t *testing.T) {
	for target, want := range map[string]string{"/d/x": "/d/x", "/d/x?": "/d/x", "/d/x?a=1;b=%zz": "/d/x?a=1;b=%zz"} {
		req := &Request{}
		req.Path, req.Query, _ = strings.Cut(target, "?")
		if got := req.FullPath(); got != want {
			t.Errorf("%s: %s", target, got)
		}
	}
}
