package main

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// Rails.cache follows the REVISION the Rails hosts run, from go_web's own until one answers.
func TestFollowRailsRevision(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Revision", "rails-revision")
	}))
	defer rails.Close()
	upstreams := filepath.Join(t.TempDir(), "upstreams")
	if err := os.WriteFile(upstreams, []byte(strings.TrimPrefix(rails.URL, "http://")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cache, err := railscache.New([]string{"127.0.0.1:1"}, "go-revision", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		followRailsRevision(web.NewRailsProxy(upstreams), cache, slog.New(slog.DiscardHandler), stop)
		close(done)
	}()
	for deadline := time.Now().Add(5 * time.Second); cache.Namespace() != "rails-revision"; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("namespace %q", cache.Namespace())
		}
	}
	close(stop)
	<-done
}
