package web

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
)

// Host is ActionDispatch::Request#host: the last X-Forwarded-Host entry when present,
// otherwise the Host header, without its port.
func Host(r *http.Request) string {
	host, _ := splitPort(rawHostWithPort(r))
	return host
}

// HostWithPort keeps the port only when it is not the scheme's default.
func HostWithPort(r *http.Request) string {
	raw := rawHostWithPort(r)
	host, port := splitPort(raw)
	if port == "" || (port == "443" && Protocol(r) == "https://") || (port == "80" && Protocol(r) == "http://") {
		return host
	}
	return raw
}

// ForwardedPort is the last X-Forwarded-Port entry, which Rack takes as the port when the
// host carries none.
func ForwardedPort(r *http.Request) string {
	return lastListEntry(r.Header.Values("X-Forwarded-Port"))
}

func rawHostWithPort(r *http.Request) string {
	if forwarded := lastListEntry(r.Header.Values("X-Forwarded-Host")); forwarded != "" {
		return forwarded
	}
	return r.Host
}

// lastListEntry is `value.split(/,\s?/).last`: the last field that isn't a trailing empty one,
// with one leading whitespace character dropped, as the separator consumes it.
func lastListEntry(values []string) string {
	joined := strings.Join(values, ",")
	if strings.TrimSpace(joined) == "" {
		return ""
	}
	for end := len(joined); end > 0; {
		start := strings.LastIndexByte(joined[:end], ',') + 1
		field := joined[start:end]
		if start > 0 && field != "" && isRubySpace(field[0]) {
			field = field[1:]
		}
		if field != "" {
			return field
		}
		end = start - 1
	}
	return ""
}

func isRubySpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

// splitPort strips a trailing `:digits`, as `sub(/:\d+$/, "")` does.
func splitPort(raw string) (host, port string) {
	i := strings.LastIndexByte(raw, ':')
	if i < 0 || i == len(raw)-1 {
		return raw, ""
	}
	for _, c := range raw[i+1:] {
		if c < '0' || c > '9' {
			return raw, ""
		}
	}
	return raw[:i], raw[i+1:]
}

// Fullpath is ActionDispatch::Request#fullpath: the raw path, plus the query when there is one.
func Fullpath(r *http.Request) string {
	path, query, _ := strings.Cut(r.RequestURI, "?")
	if query == "" {
		return path
	}
	return path + "?" + query
}

// Protocol is ActionDispatch::Request#protocol: like Rack, the last X-Forwarded-Proto
// entry wins.
func Protocol(r *http.Request) string {
	if strings.TrimSpace(lastListEntry(r.Header.Values("X-Forwarded-Proto"))) == "https" || r.TLS != nil {
		return "https://"
	}
	return "http://"
}

// requestID follows ActionDispatch::RequestId: reuse a sanitized X-Request-Id, else mint a UUID.
func requestID(r *http.Request) string {
	if id := sanitizeRequestID(r.Header.Get("X-Request-Id")); id != "" {
		return id
	}
	return NewUUID()
}

// NewUUID is SecureRandom.uuid.
func NewUUID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	var out [36]byte
	hex.Encode(out[0:8], b[0:4])
	hex.Encode(out[9:13], b[4:6])
	hex.Encode(out[14:18], b[6:8])
	hex.Encode(out[19:23], b[8:10])
	hex.Encode(out[24:], b[10:])
	out[8], out[13], out[18], out[23] = '-', '-', '-', '-'
	return string(out[:])
}

// sanitizeRequestID is `gsub(/[^\w\-@]/, "").first(255)`.
func sanitizeRequestID(id string) string {
	keep := func(c byte) bool {
		return c == '_' || c == '-' || c == '@' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
	}
	clean := true
	for i := 0; i < len(id); i++ {
		if !keep(id[i]) {
			clean = false
			break
		}
	}
	if !clean {
		var b strings.Builder
		for i := 0; i < len(id); i++ {
			if keep(id[i]) {
				b.WriteByte(id[i])
			}
		}
		id = b.String()
	}
	if len(id) > 255 {
		id = id[:255]
	}
	return id
}
