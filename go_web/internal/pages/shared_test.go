package pages

import (
	"context"
	"html"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

func withHeaders(kv ...string) *rails.Request {
	h := http.Header{}
	for i := 0; i+1 < len(kv); i += 2 {
		h.Add(kv[i], kv[i+1])
	}
	return &rails.Request{HTTP: &http.Request{Header: h}}
}

func productionEnv(t *testing.T) *web.Environment {
	t.Helper()
	env, err := web.LoadEnvironment(func(k string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func productionShared(t *testing.T, stripeSignupOff bool) *Shared {
	t.Helper()
	return NewShared(productionEnv(t), func(context.Context) (bool, error) { return stripeSignupOff, nil })
}

// The signed-out share blocks give what production sent on the expired page in
// ../inertia/testdata, which was requested without Accept-Language.
func TestSignedOutMatchesProduction(t *testing.T) {
	b, err := os.ReadFile("../inertia/testdata/production_expired_page.html")
	if err != nil {
		t.Fatal(err)
	}
	page := html.UnescapeString(regexp.MustCompile(`data-page="([^"]*)"`).FindStringSubmatch(string(b))[1])
	parsed, err := rails.ParseJSON([]byte(page))
	if err != nil {
		t.Fatal(err)
	}
	props := parsed.(*rails.Hash).Value("props").(*rails.Hash)
	want := rails.NewHash()
	for _, k := range props.Keys() {
		want.Set(k, props.Value(k))
		if k == "title" {
			break
		}
	}

	got, err := productionShared(t, true).SignedOut(context.Background(), Request{
		Req:         withHeaders("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"),
		Session:     session.New(),
		CSRFToken:   props.Value("authenticity_token").(string),
		ScriptNonce: props.Value("csp_nonce").(string),
		Title:       props.Value("title").(string),
	})
	if err != nil {
		t.Fatal(err)
	}
	if g, w := rails.EncodeJSON(got), rails.EncodeJSON(want); g != w {
		t.Errorf("shared props differ:\n got %s\nwant %s", g, w)
	}
}

func TestIsMobile(t *testing.T) {
	withParam := session.New()
	withParam.Set("mobile_param", "0")
	cases := []struct {
		r    Request
		want string
	}{
		{Request{Req: withHeaders("User-Agent", "Mozilla/5.0 (iPhone) Mobile/15E148")}, `{"is_mobile":true}`},
		{Request{Req: withHeaders("User-Agent", "Mozilla/5.0 (webOS/2.0)")}, `{"is_mobile":true}`},
		{Request{Req: withHeaders("User-Agent", "mobile")}, `{"is_mobile":false}`},
		// A repeated header is read joined, as Puma passes it.
		{Request{Req: withHeaders("User-Agent", "Foo", "User-Agent", "Mobile")}, `{"is_mobile":true}`},
		// session[:mobile_param] decides when it's set.
		{Request{Req: withHeaders("User-Agent", "Mobile"), Session: withParam}, `{"is_mobile":false}`},
	}
	for _, c := range cases {
		if got := UserAgentInfoJSON(c.r); got != c.want {
			t.Errorf("%v: got %s", c.r.Req.HTTP.Header, got)
		}
	}
}

func TestFlashProps(t *testing.T) {
	flash := func(raw string) *session.Session {
		s := session.Parse([]byte(`{"session_id":"x","flash":` + raw + `}`))
		if s == nil {
			t.Fatalf("unparsable %s", raw)
		}
		return s
	}
	cases := map[string]string{
		`{"discard":[],"flashes":{"warning":"Preparing","notice":"Saved"}}`: `{"message":"Preparing","status":"warning"}`,
		`{"discard":["alert"],"flashes":{"alert":"Gone","info":"Hi"}}`:      `{"message":"Hi","status":"info"}`,
		`{"flashes":{"alert":"","notice":"Saved"}}`:                         `{"message":"Saved","status":"success"}`,
		`{"discard":[],"flashes":{"other":"x"}}`:                            `null`,
		`"not a hash"`:                                                      `null`,
	}
	for raw, want := range cases {
		got, err := FlashProps(flash(raw))
		if err != nil {
			t.Fatal(err)
		}
		if g := rails.EncodeJSON(got); g != want {
			t.Errorf("%s: got %s, want %s", raw, g, want)
		}
	}
	if got, err := FlashProps(session.New()); got != nil || err != nil {
		t.Errorf("no flash: %v %v", got, err)
	}
	// from_session_value raises on the first; the second is a shape this port leaves to Rails.
	for _, raw := range []string{`{"discard":[]}`, `{"discard":"alert","flashes":{}}`} {
		if _, err := FlashProps(flash(raw)); err != ErrUnported {
			t.Errorf("%s: %v", raw, err)
		}
	}
}

func TestSignedOutLeavesToRailsWhatOnlyItBuilds(t *testing.T) {
	withErrors := session.New()
	withErrors.Set("inertia_errors", rails.NewHash())
	unevaluable := NewShared(productionEnv(t), func(context.Context) (bool, error) { return false, flipper.ErrUnevaluable })
	for name, c := range map[string]struct {
		shared *Shared
		r      Request
	}{
		"tied locales MRI orders": {productionShared(t, false), Request{Req: withHeaders("Accept-Language", strings.Repeat("a,", 7))}},
		"session errors":          {productionShared(t, false), Request{Req: withHeaders(), Session: withErrors}},
		"an expression gate":      {unevaluable, Request{Req: withHeaders()}},
	} {
		if _, err := c.shared.SignedOut(context.Background(), c.r); err != ErrUnported {
			t.Errorf("%s: got %v", name, err)
		}
	}
	// Repeated Accept-Language headers are read joined: * then fr.
	props, err := productionShared(t, false).SignedOut(context.Background(), Request{Req: withHeaders("Accept-Language", "*", "Accept-Language", "fr")})
	if err != nil || props.Get("locale") != "fr" {
		t.Errorf("got %v %v", props.Get("locale"), err)
	}
}

func TestDesignSettingsJSONIsTheProp(t *testing.T) {
	shared := productionShared(t, false)
	props, err := shared.SignedOut(context.Background(), Request{Req: withHeaders()})
	if err != nil {
		t.Fatal(err)
	}
	if got := rails.EncodeJSON(props.Get("design_settings")); got != shared.DesignSettingsJSON() {
		t.Errorf("%s != %s", got, shared.DesignSettingsJSON())
	}
}
