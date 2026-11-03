package web

import (
	"crypto/sha256"
	"encoding/hex"
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

// HTMLEscape is ERB::Util.html_escape. Rails applies it to robots/index.erb because the
// template name carries no format; an index.text.erb would not be escaped.
func HTMLEscape(s string) string {
	return htmlEscaper.Replace(s)
}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")
