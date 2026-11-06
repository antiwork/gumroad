package licenses

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

func TestARequestWithASessionCookieGoesToRails(t *testing.T) {
	var gotBody string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusTeapot)
	}))
	defer upstream.Close()
	file := filepath.Join(t.TempDir(), "upstreams")
	if err := os.WriteFile(file, []byte(strings.TrimPrefix(upstream.URL, "http://")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	h := newHarness(t, nil, nil)
	h.handler.proxy, h.handler.session = web.NewRailsProxy(file), "_gumroad_app_session"
	w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "license_key=x&product_id=y",
		headers: map[string]string{"Cookie": "_gumroad_app_session=abc"}})
	if w.Code != http.StatusTeapot || gotBody != "license_key=x&product_id=y" {
		t.Fatalf("got %d, Rails read %q", w.Code, gotBody)
	}
}
