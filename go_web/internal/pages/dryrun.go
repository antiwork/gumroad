package pages

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// dryRunHeader asks for the page without its writes, for comparing the port with Rails. It
// carries "<unix time>:<HMAC>" over the method, host, full path and time, under a key
// derived from secret_key_base, so only someone who could already forge any session can
// send it. Each header works once.
const dryRunHeader = "X-Go-Web-Dry-Run"

// A signed header is good from dryRunSkew before its time to dryRunMaxAge after it.
const (
	dryRunMaxAge = time.Minute
	dryRunSkew   = 5 * time.Second
)

// DryRunKey derives the dry run's HMAC key from secret_key_base, nil for none. Every page
// shares it, and the parity checks sign with this label.
func DryRunKey(secretKeyBase string) []byte {
	if strings.TrimSpace(secretKeyBase) == "" {
		return nil
	}
	sum := sha256.Sum256([]byte("go_web download page dry run\x00" + secretKeyBase))
	return sum[:]
}

// SignDryRun is the header value for a request, as a parity check makes it. fullPath is
// the request target: the path, then the query when there is one.
func SignDryRun(key []byte, method, host, fullPath string, at time.Time) string {
	ts := strconv.FormatInt(at.Unix(), 10)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(method + "\n" + host + "\n" + fullPath + "\n" + ts))
	return ts + ":" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// dryRunOnceTTL outlives the window, so a header can't be used again while it is good.
const dryRunOnceTTL = dryRunMaxAge + dryRunSkew + time.Minute

type dryRunState int

const (
	dryRunNone dryRunState = iota
	dryRunValid
	// dryRunRefused is a valid header already used, or one whose use Redis couldn't record:
	// running the page for real would do the writes the header asked to skip.
	dryRunRefused
)

// dryRunState is whether r carries a valid dry-run header, and whether it is unused.
func (c *Controller) dryRunState(r *http.Request) dryRunState {
	value := r.Header.Get(dryRunHeader)
	if value == "" || len(c.DryRunKey) == 0 || c.DryRunOnce == nil {
		return dryRunNone
	}
	ts, _, ok := strings.Cut(value, ":")
	if !ok {
		return dryRunNone
	}
	unix, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return dryRunNone
	}
	at := time.Unix(unix, 0)
	if d := c.Now().Sub(at); d > dryRunMaxAge || d < -dryRunSkew {
		return dryRunNone
	}
	if !hmac.Equal([]byte(value), []byte(SignDryRun(c.DryRunKey, r.Method, r.Host, r.RequestURI, at))) {
		return dryRunNone
	}
	ctx, cancel := context.WithTimeout(r.Context(), dryRunOnceTimeout)
	defer cancel()
	if fresh, err := c.DryRunOnce.SetNX(ctx, "go_web:dry_run:"+value, 1, dryRunOnceTTL).Result(); err != nil || !fresh {
		return dryRunRefused
	}
	return dryRunValid
}

const dryRunOnceTimeout = time.Second

type dryRunKey struct{}

// isDryRun is whether Serve marked the request a dry run.
func isDryRun(r *http.Request) bool {
	v, _ := r.Context().Value(dryRunKey{}).(bool)
	return v
}

// DryRunStore is where used dry-run headers are remembered.
type DryRunStore interface {
	SetNX(ctx context.Context, key string, value any, expiration time.Duration) *redis.BoolCmd
}

// answerDryRunFallback tells the parity check which fallback it hit, without sending the
// request on to Rails, whose page would write.
func answerDryRunFallback(w http.ResponseWriter, reason string) {
	w.Header().Set("X-Go-Web-Fallback", reason)
	w.WriteHeader(http.StatusNoContent)
}
