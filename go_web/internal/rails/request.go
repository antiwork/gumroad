// Package rails emulates the Rack stack and ActionDispatch around a ported action:
// Rack::UTF8Sanitizer, param parsing, format negotiation, remote_ip, rack-cors,
// Rack::ETag and ConditionalGet, the public exceptions app, and the Ruby value semantics
// params carry. App logic stays in the packages that port each controller.
package rails

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

// The ways a request fails before any action code runs; RenderParseError answers each one.
var (
	// ActionController::BadRequest, which CatchBadRequestErrors answers with a 400.
	ErrBadRequest = errors.New("invalid request parameters")
	// ActionDispatch::Http::Parameters::ParseError, a 400 from the public exceptions app.
	ErrParse = errors.New("error occurred while parsing request parameters")
	// Mime::Type::InvalidMimeType from Accept or Content-Type, an empty 406.
	ErrNotAcceptable = errors.New("invalid mime type")
	// ErrFailsafe is an error whose error page also raises, which ShowExceptions answers
	// with its failsafe 500.
	ErrFailsafe = errors.New("error Rails answers with its failsafe response")
	// Past maxBodyBytes; nginx answers these first in practice.
	ErrBodyTooLarge = errors.New("request body too large")
	// ActionDispatch::RemoteIp::IpSpoofAttackError, a 500.
	ErrIPSpoofing = errors.New("IP spoofing attack")
)

// A safety cap at nginx's client_max_body_size, which nginx enforces first.
const maxBodyBytes = 10 << 20

// Stack holds what the middleware reads from config: rack-cors' rules.
type Stack struct {
	Env                *web.Environment
	customDomainOrigin *regexp.Regexp
}

// NewStack takes CUSTOM_DOMAIN, whose rack-cors rule web.Environment doesn't carry.
func NewStack(env *web.Environment, customDomain string) *Stack {
	s := &Stack{Env: env}
	if customDomain != "" {
		// rack-cors compiles a host origin to ^scheme://host$ with Ruby's line anchors.
		s.customDomainOrigin = regexp.MustCompile(`(?m)^[a-z][a-z0-9.+-]*://` + regexp.QuoteMeta(customDomain) + `$`)
	}
	return s
}

// Request is an HTTP request as an action sees it once the stack has parsed it.
type Request struct {
	HTTP   *http.Request
	Method string
	// Path is PATH_INFO: the raw path as the sanitizer leaves it.
	Path string
	// Query is QUERY_STRING as the sanitizer leaves it.
	Query   string
	Params  *Hash
	Cookies map[string]*string
	Host    string
	// Formats is request.formats as symbols; VaryAccept is should_apply_vary_header?.
	Formats    []string
	VaryAccept bool
	Now        time.Time
	// RawPost is request.raw_post: the body after Rack::UTF8Sanitizer rewrote it.
	RawPost []byte
	// BodyParams is request.request_parameters, before query and path params merge over it.
	BodyParams *Hash
	// ContentMimeType is content_mime_type's symbol, "" when absent or unregistered.
	ContentMimeType string
	cors            http.Header
}

// Parse runs the sanitizer and ActionDispatch's parsing. pathParams are
// the route's (controller, action, id, format...), which win over query and body keys.
func (s *Stack) Parse(r *http.Request, pathParams [][2]string, now time.Time) (*Request, error) {
	rawPath, rawQuery, _ := strings.Cut(r.RequestURI, "?")
	if strings.HasPrefix(rawPath, "http://") || strings.HasPrefix(rawPath, "https://") {
		rawPath = r.URL.EscapedPath()
	}
	req := &Request{
		HTTP:    r,
		Method:  r.Method,
		Path:    sanitizeURIEncoded(rawPath),
		Cookies: parseCookies(r.Header.Values("Cookie")),
		Host:    web.Host(r),
		Now:     now,
		cors:    s.corsHeaders(r),
	}

	body := []byte{}
	if r.Body != nil {
		data, err := io.ReadAll(http.MaxBytesReader(nil, r.Body, maxBodyBytes))
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, ErrBodyTooLarge
		}
		if err != nil {
			return nil, ErrBadRequest
		}
		body = data
	}
	contentTypes, hasContentType := r.Header["Content-Type"]
	contentType := ""
	if hasContentType && len(contentTypes) > 0 {
		contentType = contentTypes[0]
	}
	mediaType := rackMediaType(contentType)
	req.RawPost = sanitizeBody(mediaType, body)
	// Rails parses request_parameters first, so a bad body decides the error.
	bodyHash, err := bodyParams(r.Method, contentType, mediaType, hasContentType, req.RawPost)
	if err != nil {
		return nil, err
	}
	// bodyParams has already rejected an invalid type.
	req.BodyParams = bodyHash
	req.ContentMimeType, _ = contentMimeType(contentType, hasContentType)
	req.Query = sanitizeURIEncoded(rawQuery)
	pairs, err := queryPairs(req.Query)
	if err != nil {
		return nil, err
	}
	query, err := fromPairs(pairs, railsParamDepthLimit)
	if err != nil {
		return nil, err
	}
	req.Params = mergeParams(bodyHash, query)
	for _, p := range pathParams {
		req.Params.Set(p[0], p[1])
	}

	req.Formats, req.VaryAccept, err = formats(req.Params.Value("format"), req.Header("Accept"), contentType, req.XHR(), req.Path)
	if err != nil {
		return nil, err
	}
	return req, nil
}

// FullPath is request.fullpath and original_fullpath: the path, then the query when there
// is one.
func (req *Request) FullPath() string {
	if req.Query == "" {
		return req.Path
	}
	return req.Path + "?" + req.Query
}

// Fallback stands in for a request whose params could not be read: Rails then takes the
// error page's format from Accept and the path alone.
func (s *Stack) Fallback(r *http.Request) *Request {
	req := &Request{HTTP: r, Method: r.Method, Host: web.Host(r), cors: s.corsHeaders(r)}
	req.Formats, _, _ = formats(nil, r.Header.Get("Accept"), r.Header.Get("Content-Type"),
		strings.Contains(strings.ToLower(r.Header.Get("X-Requested-With")), "xmlhttprequest"), r.URL.Path)
	return req
}

// sanitizeBody is sanitize_rack_input for the content types the sanitizer rewrites.
func sanitizeBody(mediaType string, data []byte) []byte {
	switch mediaType {
	case "text/plain", "application/json", "text/javascript":
		return []byte(sanitizeString(strings.TrimPrefix(string(data), "\xef\xbb\xbf")))
	case "application/x-www-form-urlencoded":
		return []byte(sanitizeURIEncoded(sanitizeString(strings.TrimPrefix(string(data), "\xef\xbb\xbf"))))
	}
	return data
}

// Header is a request header as Rails reads it from the env: sanitized, with repeated
// headers joined.
func (req *Request) Header(name string) string {
	return sanitizeString(strings.Join(req.HTTP.Header.Values(name), ", "))
}

func (req *Request) HasHeader(name string) bool {
	_, ok := req.HTTP.Header[http.CanonicalHeaderKey(name)]
	return ok
}

// Referrer is request.referrer, which the sanitizer URI-normalizes; nil when absent.
func (req *Request) Referrer() *string {
	if !req.HasHeader("Referer") {
		return nil
	}
	v := sanitizeURIEncoded(strings.Join(req.HTTP.Header.Values("Referer"), ", "))
	return &v
}

// UserAgent is request.user_agent; nil when absent.
func (req *Request) UserAgent() *string {
	if !req.HasHeader("User-Agent") {
		return nil
	}
	v := req.Header("User-Agent")
	return &v
}

func (req *Request) XHR() bool {
	return strings.Contains(strings.ToLower(req.Header("X-Requested-With")), "xmlhttprequest")
}

// Param is params[name], nil when absent.
func (req *Request) Param(name string) any {
	if req.Params == nil {
		return nil
	}
	return req.Params.Value(name)
}

// Safe is request.get? || request.head?, which CSRF and ConditionalGet use.
func (req *Request) Safe() bool { return req.Method == http.MethodGet || req.Method == http.MethodHead }

// Get is request.get?, which is false for HEAD.
func (req *Request) Get() bool { return req.Method == http.MethodGet }

// Format is request.format's symbol; "" is Mime::NullType.
func (req *Request) Format() string {
	if len(req.Formats) == 0 {
		return ""
	}
	return req.Formats[0]
}

// HasCookie is whether the request carries the cookie.
func (req *Request) HasCookie(name string) bool {
	_, ok := req.Cookie(name)
	return ok
}

// Cookie is cookies[name]; ok is false when the cookie is absent or valueless (nil).
func (req *Request) Cookie(name string) (string, bool) {
	v := req.Cookies[name]
	if v == nil {
		return "", false
	}
	return *v, true
}

var trustedProxies = func() []netip.Prefix {
	var prefixes []netip.Prefix
	for _, p := range []string{"127.0.0.0/8", "::1/128", "fc00::/7", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fe80::/10"} {
		prefixes = append(prefixes, netip.MustParsePrefix(p))
	}
	return prefixes
}()

// RemoteIP is request.remote_ip: actionpack-cloudflare's CF-Connecting-IP when the header
// is there at all, else ActionDispatch::RemoteIp::GetIp with the default trusted proxies.
func (req *Request) RemoteIP() (string, error) {
	if req.HasHeader("CF-Connecting-IP") {
		return req.Header("CF-Connecting-IP"), nil
	}
	remoteAddr, _, err := net.SplitHostPort(req.HTTP.RemoteAddr)
	if err != nil {
		remoteAddr = req.HTTP.RemoteAddr
	}
	clientIPs := reverse(validIPs(strings.FieldsFunc(req.Header("Client-Ip"), isIPSeparator)))
	forwardedIPs := reverse(validIPs(req.forwardedFor()))
	if len(clientIPs) > 0 && len(forwardedIPs) > 0 && !contains(forwardedIPs, clientIPs[len(clientIPs)-1]) {
		return "", ErrIPSpoofing
	}
	ips := append(append([]string{}, forwardedIPs...), clientIPs...)
	for _, ip := range append(append([]string{}, ips...), remoteAddr) {
		if !trustedProxy(ip) {
			return ip, nil
		}
	}
	if len(ips) > 0 {
		return ips[len(ips)-1], nil
	}
	return remoteAddr, nil
}

// forwardedFor is Rack's forwarded_for: Forwarded's for= values win over X-Forwarded-For.
func (req *Request) forwardedFor() []string {
	var out []string
	for _, element := range strings.Split(req.Header("Forwarded"), ",") {
		for _, pair := range strings.Split(element, ";") {
			key, value, ok := strings.Cut(strings.TrimSpace(pair), "=")
			if ok && strings.EqualFold(key, "for") {
				out = append(out, stripPort(strings.Trim(value, `"`)))
			}
		}
	}
	if len(out) > 0 {
		return out
	}
	for _, entry := range strings.FieldsFunc(req.Header("X-Forwarded-For"), func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
		out = append(out, stripPort(entry))
	}
	return out
}

func stripPort(authority string) string {
	if strings.HasPrefix(authority, "[") {
		if end := strings.IndexByte(authority, ']'); end > 0 {
			return authority[1:end]
		}
	}
	if strings.Count(authority, ":") == 1 {
		host, _, _ := strings.Cut(authority, ":")
		return host
	}
	return authority
}

func isIPSeparator(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r' }

func validIPs(ips []string) []string {
	var out []string
	for _, ip := range ips {
		if _, err := netip.ParseAddr(ip); err == nil {
			out = append(out, ip)
		}
	}
	return out
}

func trustedProxy(ip string) bool {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}
	for _, p := range trustedProxies {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

func reverse(s []string) []string {
	out := make([]string, len(s))
	for i, v := range s {
		out[len(s)-1-i] = v
	}
	return out
}

func contains(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}
