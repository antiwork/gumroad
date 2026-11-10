// Package webhooks ports ForeignWebhooksController's #stripe, #stripe_connect, #paypal,
// #sendgrid, #mediaconvert and #sns_aws_config. The cookies ApplicationController's filters set on
// them (set_gumroad_guid's and the like) are left out: no provider keeps or returns them.
package webhooks

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// Per-route caps under nginx's 10M: SNS and PayPal payloads are a few KB, Stripe events
	// and SendGrid batches run larger.
	maxBodyBytes      = 1 << 20
	maxLargeBodyBytes = 4 << 20
	// A request peaks near 16x its body (raw read, Parse's copy, RawPost, the params, the
	// job and its JSON), so 8 MiB of bodies in flight is ~128 MiB of a ~256 MB task.
	inFlightBodyBytes = 8 << 20
	minRequestWeight  = 64 << 10
	enqueueTimeout    = 5 * time.Second

	successJSON = `{"success":true}`
	failureJSON = `{"success":false}`
)

// The workers' sidekiq_options.
var (
	stripeJob       = sidekiq.Options{Class: "HandleStripeEventWorker", Queue: "default", Retry: 10}
	sendgridJob     = sidekiq.Options{Class: "HandleSendgridEventJob", Queue: "low", Retry: 5}
	mediaconvertJob = sidekiq.Options{Class: "HandleSnsMediaconvertEventWorker", Queue: "default", Retry: 5}
	awsConfigJob    = sidekiq.Options{Class: "HandleSnsAwsConfigEventWorker", Queue: "low", Retry: 5}
)

// errRailsRaises marks a failure Rails raises from instead of handling, which the
// public exceptions app answers with a 500.
var errRailsRaises = errors.New("Rails raises")

// SendgridPublicKeyEnvVars is ForeignWebhooksController::SENDGRID_WEBHOOK_PUBLIC_KEY_ENV_VARS.
var SendgridPublicKeyEnvVars = []string{
	"SENDGRID_GR_CREATORS_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GR_CUSTOMERS_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GR_CUSTOMERS_LEVEL_2_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GUMROAD_TRANSACTIONS_WEBHOOK_PUBLIC_KEY",
}

// SendgridPublicKeys reads SendgridPublicKeyEnvVars in order.
func SendgridPublicKeys(get func(string) string) []string {
	keys := make([]string, len(SendgridPublicKeyEnvVars))
	for i, name := range SendgridPublicKeyEnvVars {
		keys[i] = get(name)
	}
	return keys
}

type Deps struct {
	// Env names the hosts GumroadDomainConstraint, which wraps these routes, allows.
	Env *web.Environment
	// Stack is the shared Rack emulation.
	Stack *rails.Stack
	// Redis is $redis (REDIS_HOST), where Flipper keeps verify_sendgrid_webhook_signatures
	// and PaypalPartnerRestCredentials its token.
	Redis redis.Cmdable
	// Sidekiq pushes to SIDEKIQ_REDIS_HOST.
	Sidekiq *sidekiq.Client
	// STRIPE__ENDPOINT_SECRET and STRIPE_CONNECT__ENDPOINT_SECRET.
	StripeEndpointSecret        string
	StripeConnectEndpointSecret string
	// PAYPAL_WEBHOOK_ID, PAYPAL_PARTNER_CLIENT_ID and PAYPAL_PARTNER_CLIENT_SECRET.
	PaypalWebhookID           string
	PaypalPartnerClientID     string
	PaypalPartnerClientSecret string
	// SendgridPublicKeys' result; blank entries are skipped, as Rails skips them.
	SendgridPublicKeys []string
	// Logger takes one warning per route left unregistered.
	Logger *slog.Logger
	Now    func() time.Time
}

// Register routes each action whose secrets are set; the rest stay on Rails. The SNS
// routes need none.
func Register(app *web.App, deps Deps) error {
	_, err := register(app, deps, newCertGetter())
	return err
}

type certGetter func(ctx context.Context, url string) ([]byte, error)

func register(app *web.App, deps Deps, getCert certGetter) (*handlers, error) {
	if deps.Env == nil || deps.Stack == nil || deps.Redis == nil || deps.Sidekiq == nil {
		return nil, errors.New("webhooks: Env, Stack, Redis and Sidekiq are required")
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	logger := deps.Logger
	if logger == nil {
		logger = slog.Default()
	}
	h := &handlers{env: deps.Env, stack: deps.Stack, notFound: deps.Stack.NotFound(), sidekiq: deps.Sidekiq, now: deps.Now, inFlight: newBudget(inFlightBodyBytes)}
	handle := func(path, action string, serve http.HandlerFunc) {
		app.Handle("POST "+path, "ForeignWebhooksController#"+action, h.onGumroadHost(serve))
	}

	if v := newStripeVerifier(deps.StripeEndpointSecret); v != nil {
		handle("/stripe-webhook", "stripe", h.stripe(v, "stripe", acceptStripeEvent))
	} else {
		logger.Warn("STRIPE__ENDPOINT_SECRET is not set, so /stripe-webhook is not served")
	}
	if v := newStripeVerifier(deps.StripeConnectEndpointSecret); v != nil {
		handle("/stripe-connect-webhook", "stripe_connect", h.stripe(v, "stripe_connect", acceptStripeConnectEvent))
	} else {
		logger.Warn("STRIPE_CONNECT__ENDPOINT_SECRET is not set, so /stripe-connect-webhook is not served")
	}
	if v := newPaypalVerifier(deps); v != nil {
		h.paypalVerifier = v
		handle("/paypal-webhook", "paypal", h.paypal(v))
	} else {
		logger.Warn("PAYPAL_WEBHOOK_ID, PAYPAL_PARTNER_CLIENT_ID or PAYPAL_PARTNER_CLIENT_SECRET is not set, so /paypal-webhook is not served")
	}

	var keys, names []string
	for i, key := range deps.SendgridPublicKeys {
		if !rails.Blank(key) {
			keys = append(keys, key)
			names = append(names, SendgridPublicKeyEnvVars[i])
		}
	}
	if len(keys) == 0 {
		logger.Warn("no SENDGRID_*_WEBHOOK_PUBLIC_KEY is set, so /sendgrid-webhook is not served")
	} else {
		v := newSendgridVerifier(keys)
		for i, key := range v.keys {
			if key.err != nil {
				logger.Warn(names[i]+" does not parse, so SendGrid verification fails once it reaches that key", "error", key.err.Error())
			}
		}
		handle("/sendgrid-webhook", "sendgrid", h.sendgrid(v, flipper.New(deps.Redis, sendgridFlag)))
	}

	sns := newSNSVerifier(getCert)
	handle("/sns-mediaconvert-webhook", "mediaconvert", h.sns(sns, "mediaconvert", mediaconvertJob, mediaconvertDelay, "Incoming SNS (MediaConvert)"))
	handle("/sns-aws-config-webhook", "sns_aws_config", h.sns(sns, "sns_aws_config", awsConfigJob, 0, "Incoming SNS (AWS Config)"))
	return h, nil
}

type handlers struct {
	env      *web.Environment
	stack    *rails.Stack
	notFound http.Handler
	sidekiq  *sidekiq.Client
	now      func() time.Time
	inFlight *budget
	// paypalVerifier is nil when /paypal-webhook is left to Rails.
	paypalVerifier *paypalVerifier
}

// onGumroadHost is GumroadDomainConstraint: on any other host no route matches. Past the
// in-flight budget it answers an empty 503, which every provider here retries.
func (h *handlers) onGumroadHost(serve http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !h.env.IsGumroadHost(web.Host(r)) {
			h.notFound.ServeHTTP(w, r)
			return
		}
		weight := int64(maxLargeBodyBytes)
		if r.ContentLength >= 0 {
			weight = min(max(r.ContentLength, minRequestWeight), maxLargeBodyBytes)
		}
		if !h.inFlight.tryAcquire(weight) {
			web.Logger(r).Warn("Webhook in-flight budget is full", "path", r.URL.Path, "content_length", r.ContentLength)
			rails.Head(w, h.stack.Fallback(r), http.StatusServiceUnavailable)
			return
		}
		defer h.inFlight.release(weight)
		serve(w, r)
	}
}

// budget is a try-only weighted semaphore.
type budget struct {
	mu          sync.Mutex
	used, limit int64
}

func newBudget(limit int64) *budget { return &budget{limit: limit} }

func (b *budget) tryAcquire(n int64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.used+n > b.limit {
		return false
	}
	b.used += n
	return true
}

func (b *budget) release(n int64) {
	b.mu.Lock()
	b.used -= n
	b.mu.Unlock()
}

// webhookRequest is a request once the Rack stack has run.
type webhookRequest struct {
	w   http.ResponseWriter
	r   *http.Request
	req *rails.Request
	raw []byte
	// body is raw_post: the body as Rack::UTF8Sanitizer leaves it.
	body []byte
	// paramsErr is a ParseError ParamsWrapper swallowed; reading params raises it again.
	paramsErr error
}

// begin runs what Rails does before any filter, whose BadRequest and 406 come first. It
// returns false once the stack has answered.
func (h *handlers) begin(w http.ResponseWriter, r *http.Request, action string, limit int64) (*webhookRequest, bool) {
	raw, err := readBody(w, r, limit)
	if err != nil {
		if errors.Is(err, rails.ErrBodyTooLarge) {
			// Rails took up to nginx's 10M, so this is a delivery Go refused and Rails wouldn't.
			web.Logger(r).Error("Webhook body over the cap", "action", action, "content_length", r.ContentLength, "limit", limit)
		}
		h.stack.RenderParseError(w, r, err)
		return nil, false
	}
	in := &webhookRequest{w: w, r: r, raw: raw}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	in.req, err = h.stack.Parse(r, [][2]string{{"controller", "foreign_webhooks"}, {"action", action}}, h.now())
	switch {
	case errors.Is(err, rails.ErrParse):
		// Parse keeps no RawPost here; the raw body differs from it only by a BOM or
		// invalid UTF-8.
		in.paramsErr, in.req, in.body = err, h.stack.Fallback(r), raw
	case err != nil:
		h.stack.RenderParseError(w, r, err)
		return nil, false
	default:
		in.body = in.req.RawPost
	}
	return in, true
}

func readBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, error) {
	if r.ContentLength > limit {
		return nil, rails.ErrBodyTooLarge
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		return nil, rails.ErrBodyTooLarge
	case err != nil:
		return nil, rails.ErrBadRequest
	}
	return body, nil
}

// push enqueues as ForeignWebhooksController does: an argument Sidekiq raises on is a
// 500, and a Redis failure is rescue_from(*REDIS_TRANSPORT_ERRORS)'s head 503. loneLow is
// parseJSON's, whose string Ruby would keep and JSON.generate refuse.
func (h *handlers) push(in *webhookRequest, job sidekiq.Options, delay time.Duration, arg any, loneLow bool) bool {
	message := "Could not enqueue " + job.Class
	if loneLow {
		h.raise(in, message, sidekiq.ErrUnserializable)
		return false
	}
	ctx, cancel := context.WithTimeout(in.r.Context(), enqueueTimeout)
	defer cancel()
	var err error
	if delay > 0 {
		_, err = h.sidekiq.PushIn(ctx, job, delay, arg)
	} else {
		_, err = h.sidekiq.Push(ctx, job, arg)
	}
	switch {
	case err == nil:
		return true
	case errors.Is(err, sidekiq.ErrUnserializable):
		h.raise(in, message, err)
	default:
		web.Logger(in.r).Error(message, "error", err.Error())
		rails.Head(in.w, in.req, http.StatusServiceUnavailable)
	}
	return false
}

// raise answers an exception the controller doesn't rescue.
func (h *handlers) raise(in *webhookRequest, message string, err error) {
	web.Logger(in.r).Error(message, "error", err.Error())
	rails.RenderException(in.w, in.req, http.StatusInternalServerError)
}
