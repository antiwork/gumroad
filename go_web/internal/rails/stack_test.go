package rails

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

var testNow = time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)

func testStack(t *testing.T, env map[string]string, customDomain string) *Stack {
	t.Helper()
	vars := map[string]string{"RAILS_ENV": "production", "REVISION": "r"}
	for k, v := range env {
		vars[k] = v
	}
	e, err := web.LoadEnvironment(func(name string) string { return vars[name] })
	if err != nil {
		t.Fatal(err)
	}
	return NewStack(e, customDomain)
}

func post(target, contentType, body string, headers ...string) *http.Request {
	r := httptest.NewRequest("POST", target, strings.NewReader(body))
	r.Host = "api.gumroad.com"
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		r.Header.Set(headers[i], headers[i+1])
	}
	return r
}

func TestParseLetsQueryBeatBodyAndPathBeatBoth(t *testing.T) {
	s := testStack(t, nil, "")
	req, err := s.Parse(post("/v2/licenses/verify.json?a=query&format=xml", "application/json", `{"a":"body","b":[1,null,2],"format":"html"}`),
		[][2]string{{"controller", "api/v2/licenses"}, {"format", "json"}}, testNow)
	if err != nil {
		t.Fatal(err)
	}
	if req.Param("a") != "query" || req.Param("format") != "json" || req.Param("controller") != "api/v2/licenses" {
		t.Errorf("params = %s", rubyInspect(req.Params))
	}
	if got := rubyInspect(req.Param("b")); got != "[1, 2]" {
		t.Errorf("deep munge: %s", got)
	}
	if !reflectEqual(req.Formats, []string{"json"}) || req.VaryAccept {
		t.Errorf("formats %v vary %v", req.Formats, req.VaryAccept)
	}
}

// request_parameters keeps the body's own values, which ParamsWrapper copies.
func TestParseKeepsTheBodyParamsAndContentMimeType(t *testing.T) {
	s := testStack(t, nil, "")
	req, err := s.Parse(post("/x?a=query", "application/json; charset=utf-8", `{"a":"body","\u0061ction":"x"}`),
		[][2]string{{"action", "create"}}, testNow)
	if err != nil {
		t.Fatal(err)
	}
	if got := rubyInspect(req.BodyParams); got != `{"a" => "body", "action" => "x"}` {
		t.Errorf("body params = %s", got)
	}
	if req.Param("a") != "query" || req.Param("action") != "create" || req.ContentMimeType != "json" {
		t.Errorf("params = %s, content mime type %q", rubyInspect(req.Params), req.ContentMimeType)
	}
	if form, err := s.Parse(post("/x", "application/x-www-form-urlencoded", "a=1"), nil, testNow); err != nil || form.ContentMimeType != "url_encoded_form" {
		t.Errorf("form: %v %v", form, err)
	}
}

func TestParseFailsWhereRailsDoes(t *testing.T) {
	s := testStack(t, nil, "")
	deep := strings.Repeat("[a]", 32)
	for name, c := range map[string]struct {
		r    *http.Request
		want error
	}{
		"bad escape in query":        {post("/x?a=%zz", "", ""), ErrBadRequest},
		"bad escape in form":         {post("/x", "application/x-www-form-urlencoded", "a=%zz"), ErrBadRequest},
		"form nested past Rack's 32": {post("/x", "application/x-www-form-urlencoded", "a"+deep+"=1"), ErrBadRequest},
		"too many form params":       {post("/x", "application/x-www-form-urlencoded", strings.Repeat("a=1&", 4097)), ErrBadRequest},
		"type clash":                 {post("/x?a=1&a[]=2", "", ""), ErrBadRequest},
		"bad JSON":                   {post("/x", "application/json", `{"a":`), ErrParse},
		"problem+json is JSON":       {post("/x", "application/problem+json", `{`), ErrParse},
		"invalid content type":       {post("/x", "nonsense", ""), ErrNotAcceptable},
		"invalid accept":             {post("/x", "", "", "Accept", "nonsense"), ErrNotAcceptable},
		"infinite accept quality":    {post("/x", "", "", "Accept", "text/html;q=1e400, application/json"), errInfiniteQuality},
		"too large":                  {post("/x", "text/plain", strings.Repeat("x", maxBodyBytes+1)), ErrBodyTooLarge},
	} {
		if _, err := s.Parse(c.r, nil, testNow); err != c.want {
			t.Errorf("%s: got %v, want %v", name, err, c.want)
		}
	}
	// The query string keeps Rails' own depth of 100.
	if _, err := s.Parse(post("/x?a"+deep+"=1", "", ""), nil, testNow); err != nil {
		t.Errorf("query depth: %v", err)
	}
	// The sanitizer escapes a trailing NUL before Rack's Safari fix could drop it.
	req, _ := s.Parse(post("/x", "application/x-www-form-urlencoded", "a=1\x00"), nil, testNow)
	if req.Param("a") != "1\x00" {
		t.Errorf("a = %q", req.Param("a"))
	}
	if req, _ := s.Parse(post("/x", "text/plain", "a=1"), nil, testNow); req.Param("a") != nil {
		t.Error("text/plain bodies are not params")
	}
	if req, _ := s.Parse(post("/x", "", "a=1"), nil, testNow); req.Param("a") != "1" {
		t.Error("a POST without a content type is form data to Rack")
	}
}

func TestParseErrorsRenderLikeRails(t *testing.T) {
	s := testStack(t, nil, "")
	for name, c := range map[string]struct {
		r           *http.Request
		status      int
		contentType string
		body        string
	}{
		"bad query, JSON accept": {post("/x?a=%zz", "", "", "Accept", "application/json"), 400, "application/json", `{"success":false}`},
		"bad query":              {post("/x?a=%zz", "", ""), 400, "text/html", ``},
		"bad JSON, JSON accept":  {post("/x", "application/json", "{", "Accept", "application/json"), 400, "application/json; charset=utf-8", `{"status":400,"error":"Bad Request"}`},
		"bad JSON":               {post("/x", "application/json", "{"), 400, "text/html; charset=utf-8", ``},
		"invalid content type":   {post("/x", "nonsense", ""), 406, "text/html; charset=utf-8", ``},
		// The error page reads formats again, so ShowExceptions falls back to its failsafe.
		"infinite Accept quality": {post("/x", "", "", "Accept", "application/json;q=1e307, text/html"), 500, "text/plain; charset=utf-8", failsafeBody},
	} {
		_, err := s.Parse(c.r, nil, testNow)
		w := httptest.NewRecorder()
		if !s.RenderParseError(w, c.r, err) {
			t.Fatalf("%s: not a parse error: %v", name, err)
		}
		if w.Code != c.status || w.Header().Get("Content-Type") != c.contentType || w.Body.String() != c.body || w.Header().Get("Vary") != "Origin" {
			t.Errorf("%s: %d %q %q %v", name, w.Code, w.Header().Get("Content-Type"), w.Body.String(), w.Header())
		}
	}
	w := httptest.NewRecorder()
	s.RenderParseError(w, post("/x", "", ""), ErrBodyTooLarge)
	if w.Code != 413 || w.Body.Len() != 0 {
		t.Errorf("413: %d %q", w.Code, w.Body.String())
	}
}

func TestResponsesCarryRackETagAndRackCors(t *testing.T) {
	s := testStack(t, nil, "")
	req, _ := s.Parse(post("/x", "", "", "Accept", "application/json", "Origin", "https://seller.example"), nil, testNow)

	w := httptest.NewRecorder()
	RenderJSON(w, req, 200, `{"a":1}`)
	h := w.Header()
	if h.Get("ETag") != web.ETag(`{"a":1}`) || h.Get("Cache-Control") != "max-age=0, private, must-revalidate" ||
		h.Get("Vary") != "Accept, Origin" || h.Get("Content-Type") != JSONContentType ||
		h.Get("Access-Control-Allow-Origin") != "*" || h.Get("Access-Control-Allow-Methods") != "GET, POST, PUT, DELETE" {
		t.Errorf("200: %v", h)
	}

	w = httptest.NewRecorder()
	RenderJSON(w, req, 404, `{"a":1}`)
	if w.Header().Get("ETag") != "" || w.Header().Get("Cache-Control") != "no-cache" {
		t.Errorf("404 render: %v", w.Header())
	}

	w = httptest.NewRecorder()
	RenderException(w, req, 500)
	if w.Body.String() != `{"status":500,"error":"Internal Server Error"}` || w.Header().Get("Cache-Control") != "" || w.Header().Get("Vary") != "Origin" {
		t.Errorf("500: %q %v", w.Body.String(), w.Header())
	}

	get := httptest.NewRequest("GET", "/x", nil)
	get.Header.Set("If-None-Match", web.ETag(`{"a":1}`))
	getReq, _ := s.Parse(get, nil, testNow)
	w = httptest.NewRecorder()
	RenderJSON(w, getReq, 200, `{"a":1}`)
	if w.Code != 304 || w.Body.Len() != 0 {
		t.Errorf("ConditionalGet: %d", w.Code)
	}
}

func TestRenderExceptionMatchesPublicExceptions(t *testing.T) {
	var responses map[string]struct {
		Status  int
		Headers map[string]string
		Body    []byte
	}
	loadFixture(t, "rails_responses.json", &responses)
	s := testStack(t, nil, "")
	for name, accept := range map[string]string{
		"404_json": "application/json, text/html",
		"404_html": "text/html",
		"404_xml":  "application/xml",
		"422_json": "application/json",
		"500_json": "application/json",
	} {
		want := responses[name]
		r := httptest.NewRequest("GET", "/x", nil)
		r.Header.Set("Accept", accept)
		req, _ := s.Parse(r, nil, testNow)
		w := httptest.NewRecorder()
		RenderException(w, req, want.Status)
		if w.Code != want.Status || w.Header().Get("Content-Type") != want.Headers["content-type"] || w.Body.String() != string(want.Body) {
			t.Errorf("%s: %d %q %q, want %d %q %q", name, w.Code, w.Header().Get("Content-Type"), w.Body.String(), want.Status, want.Headers["content-type"], want.Body)
		}
	}
}

func TestRackCorsRulesBeyondTheAPIHost(t *testing.T) {
	for name, c := range map[string]struct {
		stack       *Stack
		host        string
		origin      string
		allowOrigin string
	}{
		"gumroad.com":          {testStack(t, nil, ""), "gumroad.com", "https://evil.example", ""},
		"custom domain origin": {testStack(t, map[string]string{"RAILS_ENV": "staging", "CUSTOM_DOMAIN": "pr.example.org"}, "pr.example.org"), "pr.example.org", "https://pr.example.org", "https://pr.example.org"},
		"development":          {testStack(t, map[string]string{"RAILS_ENV": "development"}, ""), "seller.localhost", "http://app.localhost:3000", "http://app.localhost:3000"},
	} {
		r := httptest.NewRequest("GET", "/x", nil)
		r.Host = c.host
		r.Header.Set("Origin", c.origin)
		req, _ := c.stack.Parse(r, nil, testNow)
		w := httptest.NewRecorder()
		Head(w, req, 200)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != c.allowOrigin {
			t.Errorf("%s: allow origin %q", name, got)
		}
		if c.allowOrigin != "" && w.Header().Get("Access-Control-Allow-Credentials") != "true" {
			t.Errorf("%s: credentials", name)
		}
	}
}

func TestNotFoundRendersThePublicPage(t *testing.T) {
	s := testStack(t, nil, "")
	for accept, want := range map[string]string{"application/json": `{"status":404,"error":"Not Found"}`, "text/html": "Page not found (404)"} {
		r := httptest.NewRequest("POST", "/nowhere", nil)
		r.Header.Set("Accept", accept)
		w := httptest.NewRecorder()
		s.NotFound().ServeHTTP(w, r)
		if w.Code != 404 || !strings.Contains(w.Body.String(), want) {
			t.Errorf("%s: %d %q", accept, w.Code, w.Body.String()[:min(60, w.Body.Len())])
		}
	}
}

func TestEncodeJSONIsActiveSupports(t *testing.T) {
	h := NewRHash().Sym("email", "a<b>&c\u2028").Str("email", "custom").Sym("at", time.Date(2026, 11, 2, 10, 0, 0, 999, time.FixedZone("", 3600))).
		Sym("n", []any{nil, true, 1.5, int64(2)}).Sym("tags", []string{"x"})
	h.Sym("email", "replaced")
	want := `{"email":"replaced","email":"custom","at":"2026-11-02T09:00:00Z","n":[null,true,1.5,2],"tags":["x"]}`
	if got := EncodeJSON(h); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if got := EncodeJSON("<\u2029\x01"); got != `"\u003c\u2029\u0001"` {
		t.Errorf("escapes: %s", got)
	}
}

func reflectEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestRenderInertiaJSONMarksTheResponse(t *testing.T) {
	s := testStack(t, nil, "")
	r := httptest.NewRequest("GET", "/x", nil)
	req, _ := s.Parse(r, nil, testNow)
	w := httptest.NewRecorder()
	RenderInertiaJSON(w, req, `{"component":"X"}`)
	if h := w.Header(); h.Get("X-Inertia") != "true" || h.Get("Vary") != "X-Inertia, Origin" || h.Get("Content-Type") != JSONContentType || h.Get("ETag") == "" {
		t.Errorf("headers %v", h)
	}
}
