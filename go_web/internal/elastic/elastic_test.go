package elastic

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCountPostsTheQueryAndReadsTheExactTotal(t *testing.T) {
	var got map[string]any
	var path string
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &got)
		io.WriteString(w, `{"hits":{"total":{"value":42,"relation":"eq"},"hits":[]}}`)
	}))
	defer s.Close()
	c, err := NewWithClient(s.URL, s.Client())
	if err != nil {
		t.Fatal(err)
	}
	n, err := c.Count(context.Background(), "purchases", map[string]any{"match_all": map[string]any{}})
	if err != nil || n != 42 || path != "/purchases/_search" || got["track_total_hits"] != true || got["size"] != 0.0 {
		t.Errorf("%d %v %s %v", n, err, path, got)
	}
}

func TestCountRefusesAnInexactTotal(t *testing.T) {
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"hits":{"total":{"value":10000,"relation":"gte"}}}`)
	}))
	defer s.Close()
	c, _ := NewWithClient(s.URL, s.Client())
	if _, err := c.Count(context.Background(), "purchases", map[string]any{}); err == nil {
		t.Error("an inexact total was accepted")
	}
}

func TestNewTakesOnlyAnHTTPSHost(t *testing.T) {
	for _, host := range []string{"https://user:secret@example.com", "http://example.com", "example.com:9200",
		"https://example.com/prefix", "https://a.example.com,https://b.example.com"} {
		if _, err := New(host); err == nil {
			t.Errorf("%q accepted", host)
		}
	}
	if _, err := New("https://search-production.us-east-1.es.amazonaws.com"); err != nil {
		t.Error(err)
	}
}
