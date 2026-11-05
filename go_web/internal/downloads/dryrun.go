package downloads

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// dryRunHeader asks for the page without its writes, for comparing the port with Rails. It
// carries "<unix time>:<HMAC>" over the method, path and time, under a key derived from
// secret_key_base, so only someone who could already forge any session can send it.
const dryRunHeader = "X-Go-Web-Dry-Run"

// dryRunWindow is how long a signed header stays good.
const dryRunWindow = 5 * time.Minute

// DryRunKey derives the dry run's HMAC key from secret_key_base.
func DryRunKey(secretKeyBase string) []byte {
	sum := sha256.Sum256([]byte("go_web download page dry run\x00" + secretKeyBase))
	return sum[:]
}

// SignDryRun is the header value for a request, as a parity check makes it.
func SignDryRun(key []byte, method, path string, at time.Time) string {
	ts := strconv.FormatInt(at.Unix(), 10)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(method + "\n" + path + "\n" + ts))
	return ts + ":" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// dryRun is whether r carries a valid dry-run header.
func (h *handler) dryRun(r *http.Request) bool {
	value := r.Header.Get(dryRunHeader)
	if value == "" || len(h.c.DryRunKey) == 0 {
		return false
	}
	ts, _, ok := strings.Cut(value, ":")
	if !ok {
		return false
	}
	unix, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return false
	}
	at := time.Unix(unix, 0)
	if d := h.c.Now().Sub(at); d > dryRunWindow || d < -dryRunWindow {
		return false
	}
	return hmac.Equal([]byte(value), []byte(SignDryRun(h.c.DryRunKey, r.Method, r.URL.Path, at)))
}

// answerDryRunFallback tells the parity check which fallback it hit, without sending the
// request on to Rails, whose page would write.
func answerDryRunFallback(w http.ResponseWriter, reason string) {
	w.Header().Set("X-Go-Web-Fallback", reason)
	w.WriteHeader(http.StatusNoContent)
}
