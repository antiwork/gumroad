package web

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
)

const (
	TextPlain = "text/plain; charset=utf-8"
	TextHTML  = "text/html; charset=utf-8"
)

// ETag is Rack::ETag's weak ETag for body.
func ETag(body string) string {
	sum := sha256.Sum256([]byte(body))
	return `W/"` + hex.EncodeToString(sum[:])[:32] + `"`
}

// WriteCacheable writes a 200 with etag, and answers a matching If-None-Match with
// Rack::ConditionalGet's empty 304. Content-Length keeps large bodies unchunked, as Puma sends them.
func WriteCacheable(w http.ResponseWriter, r *http.Request, contentType, etag, body string) {
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	io.WriteString(w, body)
}

// InternalServerError stands in for the 500 Rails renders from public/500.html.
func InternalServerError(w http.ResponseWriter) {
	w.Header().Set("Content-Type", TextPlain)
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusInternalServerError)
	io.WriteString(w, "We're sorry, but something went wrong.\n")
}

// statusClientClosedRequest is nginx's 499, which it logs for these requests too.
const statusClientClosedRequest = 499

// ClientLeft reports whether err is r's own cancellation: the client went away, so nothing
// failed. If so it answers the request, whose line then logs 499 instead of a 500 no one
// received.
func ClientLeft(w http.ResponseWriter, r *http.Request, err error) bool {
	if ctxErr := r.Context().Err(); ctxErr == nil || !errors.Is(err, ctxErr) {
		return false
	}
	clientLeft(w, r, err)
	return true
}

func clientLeft(w http.ResponseWriter, r *http.Request, err error) {
	Logger(r).Info("client left", "error", err.Error())
	w.WriteHeader(statusClientClosedRequest)
}

// HTMLEscape is ERB::Util.html_escape, which <%= %> output and tag attributes go through.
// Rails applies it to robots/index.erb because the template name carries no format; an
// index.text.erb would not be escaped.
func HTMLEscape(s string) string {
	return htmlEscaper.Replace(s)
}

// WriteHTMLEscaped writes HTMLEscape(s) without building the escaped copy.
func WriteHTMLEscaped(b *strings.Builder, s string) {
	htmlEscaper.WriteString(b, s)
}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")
