package rails

import (
	"embed"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

// Copies of public/404.html, 422.html and 500.html, which ActionDispatch::PublicExceptions
// serves; a test keeps them in step with the repository's.
//
//go:embed public/*.html
var publicPages embed.FS

const (
	JSONContentType = "application/json; charset=utf-8"
	// Rack::ETag's cache_control and no_cache_control as Rails configures them.
	etagCacheControl = "max-age=0, private, must-revalidate"
	noCache          = "no-cache"
	corsMaxAge       = "7200"
)

// writeBody sends a response through the stack: rack-cors' headers and Vary, then Rack::ETag
// and ConditionalGet unless the exceptions app answered, which sits outside them. rendered
// marks a controller `render`, which adds Vary: Accept.
func writeBody(w http.ResponseWriter, req *Request, status int, contentType, body, etag string, rendered, exception bool) {
	h := w.Header()
	for name, values := range req.cors {
		if h.Get(name) == "" {
			h[name] = values
		}
	}
	var vary []string
	if existing := h.Get("Vary"); existing != "" {
		vary = append(vary, existing)
	}
	if rendered && req.VaryAccept {
		vary = append(vary, "Accept")
	}
	h.Set("Vary", strings.Join(append(vary, "Origin"), ", "))
	if !exception {
		if (status == http.StatusOK || status == http.StatusCreated) && body != "" {
			if etag == "" {
				etag = web.ETag(body)
			}
			h.Set("ETag", etag)
			if h.Get("Cache-Control") == "" {
				h.Set("Cache-Control", etagCacheControl)
			}
			if req.Safe() && req.HTTP.Header.Get("If-None-Match") == etag {
				h.Del("Content-Type")
				w.WriteHeader(http.StatusNotModified)
				return
			}
		} else if h.Get("Cache-Control") == "" {
			h.Set("Cache-Control", noCache)
		}
	}
	if contentType != "" {
		h.Set("Content-Type", contentType)
	}

	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	if req.Method != http.MethodHead {
		io.WriteString(w, body)
	}
}

// Static is a constant body with its ETag worked out once.
type Static struct {
	Body string
	etag string
}

func NewStatic(body string) Static { return Static{Body: body, etag: web.ETag(body)} }

// RenderStaticJSON is RenderJSON for a constant body.
func RenderStaticJSON(w http.ResponseWriter, req *Request, status int, s Static) {
	writeBody(w, req, status, JSONContentType, s.Body, s.etag, true, false)
}

// SendStatic is send_data(body, type:, disposition: "inline") for a constant body.
// expires_now is the caller's Cache-Control: no-cache.
func SendStatic(w http.ResponseWriter, req *Request, contentType string, s Static) {
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Content-Transfer-Encoding", "binary")
	writeBody(w, req, http.StatusOK, contentType, s.Body, s.etag, false, false)
}

// RenderJSON is `render json:` with a body the caller encoded (see EncodeJSON).
func RenderJSON(w http.ResponseWriter, req *Request, status int, body string) {
	writeBody(w, req, status, JSONContentType, body, "", true, false)
}

// Head is ActionController::Head#head: no body, and Mime[formats.first] as the content
// type, without a charset.
func Head(w http.ResponseWriter, req *Request, status int) {
	contentType := ContentTypeFor(req.Format())
	if contentType == "" {
		contentType = "text/html"
	}
	writeBody(w, req, status, contentType, "", "", false, false)
}

// RedirectTo is redirect_to with an absolute location: a 302 with an empty body.
func RedirectTo(w http.ResponseWriter, req *Request, location string) {
	RedirectWithStatus(w, req, location, http.StatusFound)
}

// RedirectWithStatus is redirect_to(location, status:).
func RedirectWithStatus(w http.ResponseWriter, req *Request, location string, status int) {
	w.Header().Set("Location", location)
	writeBody(w, req, status, web.TextHTML, "", "", false, false)
}

var reasonPhrases = map[int]string{
	http.StatusBadRequest:          "Bad Request",
	http.StatusNotFound:            "Not Found",
	http.StatusNotAcceptable:       "Not Acceptable",
	http.StatusUnprocessableEntity: "Unprocessable Content",
	http.StatusInternalServerError: "Internal Server Error",
}

// RenderException is ShowExceptions handing status to ActionDispatch::PublicExceptions:
// JSON, XML or YAML for those formats, else public/<status>.html, else an empty page. The
// exception also skips ActionDispatch::Cookies' write, so no cookie goes out, and drops the
// controller's headers, debug_headers' X-Revision and X-GR among them.
func RenderException(w http.ResponseWriter, req *Request, status int) {
	h := w.Header()
	for _, name := range []string{"Cache-Control", "ETag", "Vary", "Set-Cookie", "Location", "Content-Disposition", "Content-Transfer-Encoding", "X-Revision", "X-GR"} {
		h.Del(name)
	}
	reason := reasonPhrases[status]
	var contentType, body string
	switch req.Format() {
	case "json":
		contentType = JSONContentType
		body = `{"status":` + strconv.Itoa(status) + `,"error":"` + reason + `"}`
	case "yaml":
		// Hash#to_yaml.
		contentType = "application/x-yaml; charset=utf-8"
		body = "---\n:status: " + strconv.Itoa(status) + "\n:error: " + reason + "\n"
	case "xml":
		contentType = "application/xml; charset=utf-8"
		body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hash>\n  <status type=\"integer\">" + strconv.Itoa(status) +
			"</status>\n  <error>" + reason + "</error>\n</hash>\n"
	default:
		contentType = web.TextHTML
		if page, err := publicPages.ReadFile("public/" + strconv.Itoa(status) + ".html"); err == nil {
			body = string(page)
		}
	}
	writeBody(w, req, status, contentType, body, "", false, true)
}

// RenderEmpty is ShowExceptions' pass_response, for a status without a public page or one
// rendered as HTML because the request's MIME type was invalid.
func RenderEmpty(w http.ResponseWriter, req *Request, status int) {
	writeBody(w, req, status, web.TextHTML, "", "", false, true)
}

// RenderBadRequest is CatchBadRequestErrors, which answers ActionController::BadRequest
// inside Rack::ETag and before ShowExceptions sees it.
func RenderBadRequest(w http.ResponseWriter, req *Request) {
	if strings.Contains(strings.Join(req.HTTP.Header.Values("Accept"), ", "), "application/json") {
		writeBody(w, req, http.StatusBadRequest, "application/json", `{"success":false}`, "", false, false)
		return
	}
	writeBody(w, req, http.StatusBadRequest, "text/html", "", "", false, false)
}

// RenderParseError answers an error from Stack.Parse and reports whether it was one.
func (s *Stack) RenderParseError(w http.ResponseWriter, r *http.Request, err error) bool {
	fallback := s.Fallback(r)
	switch {
	case errors.Is(err, ErrBodyTooLarge):
		w.WriteHeader(http.StatusRequestEntityTooLarge)
	case errors.Is(err, ErrBadRequest):
		RenderBadRequest(w, fallback)
	case errors.Is(err, ErrParse):
		RenderException(w, fallback, http.StatusBadRequest)
	case errors.Is(err, ErrNotAcceptable):
		RenderEmpty(w, fallback, http.StatusNotAcceptable)
	case errors.Is(err, ErrFailsafe):
		RenderFailsafe(w, fallback)
	default:
		return false
	}
	return true
}

// failsafeBody is ShowExceptions#render_exception's response when rendering the error page
// raises too.
const failsafeBody = "500 Internal Server Error\n" +
	"If you are the administrator of this website, then please read this web " +
	"application's log file and/or the web server's log file to find out what " +
	"went wrong."

// RenderFailsafe is that response, through the middleware outside ShowExceptions as its
// other responses are.
func RenderFailsafe(w http.ResponseWriter, req *Request) {
	writeBody(w, req, http.StatusInternalServerError, "text/plain; charset=utf-8", failsafeBody, "", false, true)
}

// NotFound is the 404 Rails renders for a path no route matches: the public exceptions
// app, in whatever format the request's params and Accept pick.
func (s *Stack) NotFound() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		req, err := s.Parse(r, nil, time.Now())
		if err != nil {
			if s.RenderParseError(w, r, err) {
				return
			}
			req = s.Fallback(r)
		}
		RenderException(w, req, http.StatusNotFound)
	})
}

// corsHeaders is config/initializers/cors.rb as rack-cors 2.0.2 applies it to a
// non-preflight request: the API hosts' public rule, development's localhost origins and
// CUSTOM_DOMAIN's credentialed rule.
func (s *Stack) corsHeaders(r *http.Request) http.Header {
	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = r.Header.Get("X-Origin")
	}
	if origin == "" {
		return nil
	}
	if contains(s.Env.ValidAPIRequestHosts, r.Host) {
		return http.Header{
			"Access-Control-Allow-Origin":   {"*"},
			"Access-Control-Allow-Methods":  {"GET, POST, PUT, DELETE"},
			"Access-Control-Expose-Headers": {""},
			"Access-Control-Max-Age":        {corsMaxAge},
		}
	}
	if (s.Env.Name == "development" && devOrigin.MatchString(origin)) || (s.customDomainOrigin != nil && s.customDomainOrigin.MatchString(origin)) {
		return http.Header{
			"Access-Control-Allow-Origin":      {origin},
			"Access-Control-Allow-Methods":     {"GET, POST, PUT, PATCH, DELETE, OPTIONS"},
			"Access-Control-Expose-Headers":    {""},
			"Access-Control-Max-Age":           {corsMaxAge},
			"Access-Control-Allow-Credentials": {"true"},
		}
	}
	return nil
}

var devOrigin = regexp.MustCompile(`\Ahttps?://(?:[a-z0-9-]+\.)*localhost(?::\d+)?\z`)

// RenderInertiaJSON is inertia_rails answering an X-Inertia request: render json: with the
// X-Inertia header the client checks for, and a Vary the renderer has set to X-Inertia, so
// Rails adds no Accept.
func RenderInertiaJSON(w http.ResponseWriter, req *Request, body string) {
	w.Header().Set("X-Inertia", "true")
	w.Header().Set("Vary", "X-Inertia")
	writeBody(w, req, http.StatusOK, JSONContentType, body, "", false, false)
}

// RenderHTML is `render html:`.
func RenderHTML(w http.ResponseWriter, req *Request, body string) {
	writeBody(w, req, http.StatusOK, web.TextHTML, body, "", true, false)
}

// RenderInertiaHTML is inertia_rails' first visit: the page through its layout, with the
// Vary: X-Inertia the renderer sets on every response.
func RenderInertiaHTML(w http.ResponseWriter, req *Request, body string) {
	w.Header().Set("Vary", "X-Inertia")
	writeBody(w, req, http.StatusOK, web.TextHTML, body, "", false, false)
}
