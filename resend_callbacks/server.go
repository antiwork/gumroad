package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

const (
	// Bodies are read before the signature is checked, so the cap keeps a burst of
	// large unsigned posts inside the task's memory. Resend and SNS payloads are a few
	// KB; Stripe events and SendGrid batches run larger.
	maxBodyBytes      = 1 << 20
	maxLargeBodyBytes = 4 << 20
	enqueueTimeout    = 5 * time.Second

	// HandleSnsMediaconvertEventWorker.perform_in(5.seconds, ...)
	mediaconvertDelay = 5 * time.Second
)

// errRailsRaises marks a failure Rails raises from instead of handling, which it
// answers with a 500.
var errRailsRaises = errors.New("Rails raises")

type enqueuer interface {
	enqueue(ctx context.Context, job jobSpec, arg any, delay time.Duration) error
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

// routeStats are one route's counts for the minute. skipped is a 200 that enqueued
// nothing; unverified is a SendGrid event enqueued while its signature check failed.
type routeStats struct {
	received, enqueued, skipped             atomic.Int64
	rejected, unverified, malformed, failed failure
}

// route is one webhook endpoint. Resend's predates the others: its count line, its
// svix_id log attribute and its 500 on a Redis failure stay as they were.
type route struct {
	path   string
	name   string // its count line's message, before " webhooks"
	sender string // its log messages' subject
	limit  int64
	job    jobSpec
	delay  time.Duration
	stats  *routeStats
	serve  func(rt *route, w http.ResponseWriter, r *http.Request)
	resend bool

	stripe   *stripeVerifier
	accept   func(event map[string]any) bool
	incoming string // the info line Rails logs for each verified SNS notification
}

type server struct {
	resend        *signatureVerifier
	filter        *eventFilter
	stripe        *stripeVerifier // nil leaves its route off
	stripeConnect *stripeVerifier
	sendgrid      *sendgridVerifier
	sendgridFlag  featureFlag
	sns           *snsVerifier
	queue         enqueuer
	logger        *slog.Logger
	now           func() time.Time

	counts struct {
		resend, stripe, stripeConnect, sendgrid, mediaconvert, awsConfig routeStats
	}
}

func (s *server) webhookRoutes() []*route {
	c := &s.counts
	routes := []*route{{path: "/resend-webhook", name: "resend", sender: "Resend", limit: maxBodyBytes, job: resendJob, stats: &c.resend, serve: s.serveResend, resend: true}}
	if s.stripe != nil {
		routes = append(routes, &route{path: "/stripe-webhook", name: "stripe", sender: "Stripe", limit: maxLargeBodyBytes, job: stripeJob, stats: &c.stripe, serve: s.serveStripe, stripe: s.stripe, accept: acceptStripeEvent})
	}
	if s.stripeConnect != nil {
		routes = append(routes, &route{path: "/stripe-connect-webhook", name: "stripe connect", sender: "Stripe", limit: maxLargeBodyBytes, job: stripeJob, stats: &c.stripeConnect, serve: s.serveStripe, stripe: s.stripeConnect, accept: acceptStripeConnectEvent})
	}
	if s.sendgrid != nil {
		routes = append(routes, &route{path: "/sendgrid-webhook", name: "sendgrid", sender: "SendGrid", limit: maxLargeBodyBytes, job: sendgridJob, stats: &c.sendgrid, serve: s.serveSendgrid})
	}
	if s.sns != nil {
		routes = append(routes,
			&route{path: "/sns-mediaconvert-webhook", name: "sns mediaconvert", sender: "SNS", limit: maxBodyBytes, job: mediaconvertJob, delay: mediaconvertDelay, stats: &c.mediaconvert, serve: s.serveSNS, incoming: "Incoming SNS (MediaConvert)"},
			&route{path: "/sns-aws-config-webhook", name: "sns aws config", sender: "SNS", limit: maxBodyBytes, job: awsConfigJob, stats: &c.awsConfig, serve: s.serveSNS, incoming: "Incoming SNS (AWS Config)"},
		)
	}
	return routes
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	for _, rt := range s.webhookRoutes() {
		mux.HandleFunc("POST "+rt.path, func(w http.ResponseWriter, r *http.Request) {
			rt.stats.received.Add(1)
			rt.serve(rt, w, r)
		})
	}
	mux.HandleFunc("GET /healthcheck", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "healthcheck")
	})
	return mux
}

func (s *server) serveResend(rt *route, w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r, rt)
	if !ok {
		return
	}

	if err := s.resend.verify(r.Header, body, s.now()); err != nil {
		s.fail(w, r, rt, &rt.stats.rejected, http.StatusBadRequest, "Error verifying Resend webhook", err)
		return
	}

	event, err := buildEvent(&requestBody{raw: body}, r.URL.Query(), r.Header.Get("Content-Type"), resendAction)
	if err != nil {
		s.fail(w, r, rt, &rt.stats.malformed, http.StatusBadRequest, "Unparseable Resend webhook body", err)
		return
	}

	if !s.filter.trackable(event) {
		rt.stats.skipped.Add(1)
		respond(w, http.StatusOK, true)
		return
	}
	if s.push(w, r, rt, event, false) {
		respond(w, http.StatusOK, true)
	}
}

func (s *server) serveStripe(rt *route, w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r, rt)
	if !ok {
		return
	}
	request, contentType := &requestBody{raw: body}, r.Header.Get("Content-Type")
	if err := rt.stripe.verify(rackHeader(r.Header, "Stripe-Signature"), body, s.now()); err != nil {
		// ActionDispatch's 400 comes first in Rails, and only differs from a raise.
		if errors.Is(err, errRailsRaises) && request.railsRejects(contentType) {
			s.notUTF8(w, r, rt)
			return
		}
		s.refuse(w, r, rt, "Error verifying Stripe webhook", err)
		return
	}
	parsed, err := request.parseRuby()
	if err != nil {
		s.fail(w, r, rt, &rt.stats.malformed, http.StatusBadRequest, "Unparseable Stripe webhook body", err)
		return
	}
	if request.unencodable() && isJSONContentType(contentType) {
		s.notUTF8(w, r, rt)
		return
	}
	event, ok := parsed.(map[string]any)
	if !ok {
		// Stripe::Event.construct_from raises on anything but an object.
		s.fail(w, r, rt, &rt.stats.failed, http.StatusInternalServerError, "Stripe webhook body is not an object", nil)
		return
	}
	// The controller tests the StripeObject, before as_json turns Infinity into nil.
	if !rt.accept(event) {
		rt.stats.skipped.Add(1)
		respond(w, http.StatusOK, false)
		return
	}
	if s.push(w, r, rt, stripeAsJSON(event), request.unencodable()) {
		respond(w, http.StatusOK, true)
	}
}

func (s *server) serveSendgrid(rt *route, w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r, rt)
	if !ok {
		return
	}
	request, contentType := &requestBody{raw: body}, r.Header.Get("Content-Type")
	signature := rackHeader(r.Header, "X-Twilio-Email-Event-Webhook-Signature")
	timestamp := rackHeader(r.Header, "X-Twilio-Email-Event-Webhook-Timestamp")
	if reason := s.sendgrid.verify(signature, timestamp, body, s.now()); reason != "" {
		// After a passing check, parsing the params gives ActionDispatch's 400 anyway.
		if request.railsRejects(contentType) {
			s.notUTF8(w, r, rt)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), enqueueTimeout)
		enforced, err := s.sendgridFlag.active(ctx)
		cancel()
		switch {
		case err != nil:
			s.failHead(w, r, rt, &rt.stats.failed, http.StatusServiceUnavailable, "Could not read "+sendgridFlag, err)
			return
		case enforced:
			s.fail(w, r, rt, &rt.stats.rejected, http.StatusInternalServerError, "Error verifying SendGrid webhook: "+reason, nil)
			return
		}
		s.count(r, rt, &rt.stats.unverified, http.StatusOK, "SendGrid webhook verification failed: "+reason, nil)
	}
	event, err := buildEvent(request, r.URL.Query(), contentType, sendgridAction)
	if err != nil {
		s.fail(w, r, rt, &rt.stats.malformed, http.StatusBadRequest, "Unparseable SendGrid webhook body", err)
		return
	}
	if s.push(w, r, rt, event, false) {
		respond(w, http.StatusOK, true)
	}
}

func (s *server) serveSNS(rt *route, w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r, rt)
	if !ok {
		return
	}
	// SNS posts text/plain, and anything that isn't a JSON object is a rejected sender.
	request := &requestBody{raw: body}
	parsed, err := request.parseRuby()
	notification, isObject := parsed.(map[string]any)
	if err != nil || !isObject {
		s.fail(w, r, rt, &rt.stats.malformed, http.StatusBadRequest, "SNS webhook body is not a JSON object", err)
		return
	}
	if request.unencodable() && isJSONContentType(r.Header.Get("Content-Type")) {
		s.notUTF8(w, r, rt)
		return
	}
	if err := s.sns.authenticate(r.Context(), notification); err != nil {
		s.refuse(w, r, rt, "Error verifying SNS message", err)
		return
	}
	s.logger.Info(rt.incoming, "notification", string(body))
	if s.push(w, r, rt, notification, request.unencodable()) {
		w.WriteHeader(http.StatusOK)
	}
}

func (s *server) readBody(w http.ResponseWriter, r *http.Request, rt *route) ([]byte, bool) {
	if r.ContentLength > rt.limit {
		s.fail(w, r, rt, &rt.stats.malformed, http.StatusRequestEntityTooLarge, rt.sender+" webhook body too large", nil)
		return nil, false
	}
	var body []byte
	var err error
	if r.ContentLength > 0 {
		body = make([]byte, r.ContentLength)
		_, err = io.ReadFull(r.Body, body)
	} else {
		body, err = io.ReadAll(http.MaxBytesReader(w, r.Body, rt.limit))
	}
	if err != nil {
		status := http.StatusBadRequest
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			status = http.StatusRequestEntityTooLarge
		}
		s.fail(w, r, rt, &rt.stats.malformed, status, "Could not read "+rt.sender+" webhook body", err)
		return nil, false
	}
	return body, true
}

// push follows ForeignWebhooksController: a Redis failure is head :service_unavailable,
// and a job JSON.generate raises on (unencodable, or errUnserializable) is a 500.
func (s *server) push(w http.ResponseWriter, r *http.Request, rt *route, arg any, unencodable bool) bool {
	message := "Could not enqueue " + rt.job.class
	if unencodable {
		s.fail(w, r, rt, &rt.stats.failed, http.StatusInternalServerError, message, errUnserializable)
		return false
	}
	ctx, cancel := context.WithTimeout(r.Context(), enqueueTimeout)
	defer cancel()
	switch err := s.queue.enqueue(ctx, rt.job, arg, rt.delay); {
	case err == nil:
		rt.stats.enqueued.Add(1)
		return true
	case rt.resend || errors.Is(err, errUnserializable):
		// A non-2xx makes the sender retry the delivery, so nothing is lost.
		s.fail(w, r, rt, &rt.stats.failed, http.StatusInternalServerError, message, err)
	default:
		s.failHead(w, r, rt, &rt.stats.failed, http.StatusServiceUnavailable, message, err)
	}
	return false
}

// refuse answers a verification failure: a 400, or a 500 where Rails raises.
func (s *server) refuse(w http.ResponseWriter, r *http.Request, rt *route, message string, err error) {
	if errors.Is(err, errRailsRaises) {
		s.fail(w, r, rt, &rt.stats.failed, http.StatusInternalServerError, message, err)
		return
	}
	s.fail(w, r, rt, &rt.stats.rejected, http.StatusBadRequest, message, err)
}

func (s *server) notUTF8(w http.ResponseWriter, r *http.Request, rt *route) {
	s.fail(w, r, rt, &rt.stats.malformed, http.StatusBadRequest, rt.sender+" webhook body is not UTF-8", nil)
}

// fail answers {"success":false}.
func (s *server) fail(w http.ResponseWriter, r *http.Request, rt *route, kind *failure, status int, message string, err error) {
	s.count(r, rt, kind, status, message, err)
	respond(w, status, false)
}

// failHead answers with an empty body, as Rails' head does.
func (s *server) failHead(w http.ResponseWriter, r *http.Request, rt *route, kind *failure, status int, message string, err error) {
	s.count(r, rt, kind, status, message, err)
	w.WriteHeader(status)
}

func (s *server) count(r *http.Request, rt *route, kind *failure, status int, message string, err error) {
	kind.count.Add(1)
	if !kind.allowLog(s.now()) {
		return
	}
	attrs := []any{"status", status}
	if rt.resend {
		attrs = []any{"svix_id", r.Header.Get("svix-id"), "status", status}
	}
	if err != nil {
		attrs = append(attrs, "error", err.Error())
	}
	level := slog.LevelWarn
	if status >= http.StatusInternalServerError {
		level = slog.LevelError
	}
	s.logger.Log(r.Context(), level, message, attrs...)
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

// rackHeader reads a header as Rails sees it: Puma joins repeated fields with ", ".
func rackHeader(header http.Header, name string) string {
	return strings.Join(header.Values(name), ", ")
}

// reportCounts logs one line per route per interval instead of one per request, and
// a last one at shutdown.
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
	for _, rt := range s.webhookRoutes() {
		c := rt.stats
		if rt.resend {
			s.logger.Info("resend webhooks",
				"received", c.received.Swap(0),
				"enqueued", c.enqueued.Swap(0),
				"filtered", c.skipped.Swap(0),
				"rejected", c.rejected.count.Swap(0),
				"malformed", c.malformed.count.Swap(0),
				"failed", c.failed.count.Swap(0),
			)
			continue
		}
		s.logger.Info(rt.name+" webhooks",
			"received", c.received.Swap(0),
			"enqueued", c.enqueued.Swap(0),
			"skipped", c.skipped.Swap(0),
			"unverified", c.unverified.count.Swap(0),
			"rejected", c.rejected.count.Swap(0),
			"malformed", c.malformed.count.Swap(0),
			"failed", c.failed.count.Swap(0),
		)
	}
}
