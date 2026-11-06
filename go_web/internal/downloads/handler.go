// Package downloads serves the download page's background polls: GET /d/:token as an
// Inertia partial reload of audio_durations and latest_media_locations
// (UrlRedirectsController#download_page). Everything else that reaches it, and every
// request whose Rails path this port leaves out, goes to Rails unchanged before anything
// is written.
package downloads

import (
	"context"
	"database/sql"
	"net/http"
	"slices"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	component = "UrlRedirects/DownloadPage"
	// Puma has no per-request deadline, but a poll reads a handful of rows.
	readTimeout = 5 * time.Second

	confirmedCookie = "confirmed_redirect"
)

// pollProps is DOWNLOAD_PAGE_POLLING_PROPS.
var pollProps = []string{"audio_durations", "latest_media_locations"}

// Config is what the action reads besides the request.
type Config struct {
	Env      *web.Environment
	DB       *sql.DB
	Stack    *rails.Stack
	Store    *session.Store
	Resolver *session.Resolver
	IDs      *obfuscate.IDs
	Proxy    *web.RailsProxy
	Meta     inertia.DefaultMeta
	Now      func() time.Time
	// Pages is the full page's config, nil to leave every full page to Rails.
	Pages *PageConfig
	// DryRunKey signs dry-run requests, and DryRunOnce remembers the ones used.
	DryRunKey  []byte
	DryRunOnce pages.DryRunStore
}

func Register(app *web.App, c *Config) {
	app.HandlePage("GET /d/{id}", "UrlRedirectsController#download_page", &handler{c: c, ctl: &pages.Controller{
		Env: c.Env, Stack: c.Stack, Store: c.Store, Resolver: c.Resolver, Proxy: c.Proxy,
		Redirects: app.Redirects(), Meta: c.Meta, Now: c.Now, DryRunKey: c.DryRunKey, DryRunOnce: c.DryRunOnce,
	}})
}

type handler struct {
	c   *Config
	ctl *pages.Controller
}

// page is the controller instance for one request.
type page struct {
	*pages.Visit
	// purchase is url_redirect.purchase once checkPermissions has loaded it.
	purchase *purchase
	// poll is a background poll; anything else is the full page.
	poll bool
}

type fallback = pages.Fallback

var errNotFound = pages.ErrNotFound

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	h.ctl.Serve(w, r, "download page poll", func(r *http.Request) (*pages.Visit, error) {
		p, err := h.prepare(ctx, r)
		if err != nil {
			return nil, err
		}
		return p.Visit, h.serve(w, p)
	})
}

// prepare parses the request and decides whether this port serves it. Nothing it does is
// visible outside the process, so any fallback it returns is safe.
func (h *handler) prepare(ctx context.Context, r *http.Request) (*page, error) {
	if reason := declined(r, h.c.Env, h.c.Pages != nil); reason != "" {
		return nil, fallback(reason)
	}
	v, err := h.ctl.Prepare(ctx, r, [][2]string{{"controller", "url_redirects"}, {"action", "download_page"}, {"id", r.PathValue("id")}},
		func(req *rails.Request) error {
			if req.Format() != "html" {
				return fallback("format")
			}
			if v, ok := req.Params.Get("display"); ok {
				if _, isString := v.(string); !isString {
					return fallback("param display")
				}
			}
			if value, ok := req.Cookie(confirmedCookie); ok && h.c.Store.Codec.Rotated(confirmedCookie, value) {
				return fallback("rotated " + confirmedCookie)
			}
			return nil
		})
	if err != nil {
		return nil, err
	}
	return &page{Visit: v, poll: pollRequest(r)}, nil
}

// declined is everything decided by the request line and headers alone. fullPages is whether
// this port renders the full page, which an Inertia visit to it still leaves to Rails.
func declined(r *http.Request, env *web.Environment, fullPages bool) string {
	host := web.Host(r)
	switch {
	case r.Method != http.MethodGet:
		return "method"
	case !env.IsGumroadHost(host):
		return "host"
	case !alnumToken(r.PathValue("id")):
		return "token"
	case !rails.SecureCookies(env.Protocol, r):
		// Rack::SSL redirects plain HTTP, and the session only commits over SSL.
		return "not ssl"
	case !pollRequest(r) && (!fullPages || pages.DeclinedHeaders(r) != ""):
		// inertia_rails reads the partial headers without X-Inertia, so Rails would render
		// a partial page here.
		return "not a poll"
	case r.ContentLength != 0 || len(r.TransferEncoding) > 0:
		// Parsing reads the body, which a fallback after it could no longer send.
		return "request body"
	}
	for _, h := range []string{"X-Inertia-Version", "X-Inertia-Partial-Except", "X-Inertia-Error-Bag"} {
		if _, ok := r.Header[h]; ok {
			return "inertia header " + h
		}
	}
	// Rails reads a repeated header joined with ", ", which is no longer a poll.
	for _, h := range []string{"X-Inertia", "X-Inertia-Partial-Component", "X-Inertia-Partial-Data"} {
		if len(r.Header.Values(h)) > 1 {
			return "repeated " + h
		}
	}
	return ""
}

// alnumToken is what UrlRedirect tokens look like; anything else needs Rails' path escaping.
func alnumToken(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

// pollRequest is download_page_polling_request?. Ruby's split drops trailing empty fields.
func pollRequest(r *http.Request) bool {
	if r.Header.Get("X-Inertia") != "true" || r.Header.Get("X-Inertia-Partial-Component") != component {
		return false
	}
	props := rails.Split(r.Header.Get("X-Inertia-Partial-Data"), ",")
	if len(props) == 0 {
		// download_page_polling_request? accepts it, but inertia_rails then renders every prop.
		return false
	}
	for _, prop := range props {
		if !slices.Contains(pollProps, prop) {
			return false
		}
	}
	return true
}
