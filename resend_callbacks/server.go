package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"
)

const (
	// Resend payloads are a few KB; the cap keeps a burst of large unsigned posts,
	// which are read before the signature is checked, inside the task's memory.
	maxBodyBytes   = 1 << 20
	enqueueTimeout = 5 * time.Second
)

type enqueuer interface {
	enqueue(ctx context.Context, event map[string]any) error
}

// failure is one way a request can fail: its minute count and a log line limited to
// one per second, since a Redis outage or a flood of bad signatures arrives
// thousands of times a second.
type failure struct {
	count   atomic.Int64
	lastLog atomic.Int64
}

func (f *failure) allowLog(now time.Time) bool {
	second := now.Unix()
	last := f.lastLog.Load()
	return last != second && f.lastLog.CompareAndSwap(last, second)
}

type server struct {
	verifier *signatureVerifier
	filter   *eventFilter
	queue    enqueuer
	logger   *slog.Logger
	now      func() time.Time

	received, filtered, enqueued atomic.Int64
	rejected, malformed, failed  failure
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /resend-webhook", s.resendWebhook)
	mux.HandleFunc("GET /healthcheck", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "healthcheck")
	})
	return mux
}

func (s *server) resendWebhook(w http.ResponseWriter, r *http.Request) {
	s.received.Add(1)

	if r.ContentLength > maxBodyBytes {
		s.fail(w, r, &s.malformed, http.StatusRequestEntityTooLarge, "Resend webhook body too large", nil)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		status := http.StatusBadRequest
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			status = http.StatusRequestEntityTooLarge
		}
		s.fail(w, r, &s.malformed, status, "Could not read Resend webhook body", err)
		return
	}

	if err := s.verifier.verify(r.Header, body, s.now()); err != nil {
		s.fail(w, r, &s.rejected, http.StatusBadRequest, "Error verifying Resend webhook", err)
		return
	}

	event, err := buildEvent(body, r.URL.Query())
	if err != nil {
		s.fail(w, r, &s.malformed, http.StatusBadRequest, "Unparseable Resend webhook body", err)
		return
	}

	if !s.filter.trackable(event) {
		s.filtered.Add(1)
		respond(w, http.StatusOK, true)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), enqueueTimeout)
	defer cancel()
	if err := s.queue.enqueue(ctx, event); err != nil {
		// A non-2xx makes Resend retry the delivery, so nothing is lost.
		s.fail(w, r, &s.failed, http.StatusInternalServerError, "Could not enqueue "+jobClass, err)
		return
	}
	s.enqueued.Add(1)
	respond(w, http.StatusOK, true)
}

func (s *server) fail(w http.ResponseWriter, r *http.Request, kind *failure, status int, message string, err error) {
	kind.count.Add(1)
	if kind.allowLog(s.now()) {
		attrs := []any{"svix_id", r.Header.Get("svix-id"), "status", status}
		if err != nil {
			attrs = append(attrs, "error", err.Error())
		}
		level := slog.LevelWarn
		if status >= http.StatusInternalServerError {
			level = slog.LevelError
		}
		s.logger.Log(r.Context(), level, message, attrs...)
	}
	respond(w, status, false)
}

func respond(w http.ResponseWriter, status int, success bool) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if success {
		io.WriteString(w, `{"success":true}`)
	} else {
		io.WriteString(w, `{"success":false}`)
	}
}

// reportCounts logs one line per interval instead of one per request, and a last
// one at shutdown.
func (s *server) reportCounts(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			s.logCounts()
			return
		case <-ticker.C:
			s.logCounts()
		}
	}
}

func (s *server) logCounts() {
	s.logger.Info("resend webhooks",
		"received", s.received.Swap(0),
		"enqueued", s.enqueued.Swap(0),
		"filtered", s.filtered.Swap(0),
		"rejected", s.rejected.count.Swap(0),
		"malformed", s.malformed.count.Swap(0),
		"failed", s.failed.count.Swap(0),
	)
}
