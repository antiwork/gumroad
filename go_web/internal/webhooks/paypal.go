package webhooks

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// PaypalPartnerRestCredentials' Redis::Namespace key, which Rails reads too.
	paypalTokenKey = "paypal_partner_rest_auth_token:token_header"
	// Every event outside paypalImmediateEvents waits this long.
	paypalDelay = 10 * time.Minute
	// The token and the verify call together, leaving the body read and the push room
	// inside the server's 30s write timeout. Rails gave the verify call alone 30s; PayPal
	// redelivers what fails here.
	paypalVerifyTimeout  = 15 * time.Second
	paypalTokenTries     = 3
	paypalTokenRetryWait = 2 * time.Second
	// Each check holds its share of the in-flight budget the other webhooks need, so past
	// this many the request gets a 503 and PayPal redelivers it.
	paypalMaxCalls         = 16
	paypalMaxResponseBytes = 64 << 10
)

var paypalJob = sidekiq.Options{Class: "HandlePaypalEventWorker", Queue: "default", Retry: 5}

// PaypalEventType::ORDER_API_EVENTS and MERCHANT_ACCOUNT_EVENTS, which
// schedule_paypal_event_processing enqueues at once.
var paypalImmediateEvents = map[string]bool{
	"CUSTOMER.DISPUTE.CREATED":                                   true,
	"CUSTOMER.DISPUTE.RESOLVED":                                  true,
	"PAYMENT.CAPTURE.COMPLETED":                                  true,
	"PAYMENT.CAPTURE.DENIED":                                     true,
	"PAYMENT.CAPTURE.REVERSED":                                   true,
	"PAYMENT.CAPTURE.REFUNDED":                                   true,
	"MERCHANT.ONBOARDING.COMPLETED":                              true,
	"MERCHANT.PARTNER-CONSENT.REVOKED":                           true,
	"CUSTOMER.MERCHANT-INTEGRATION.CAPABILITY-UPDATED":           true,
	"CUSTOMER.MERCHANT-INTEGRATION.PRODUCT-SUBSCRIPTION-UPDATED": true,
	"CUSTOMER.MERCHANT-INTEGRATION.SELLER-EMAIL-CONFIRMED":       true,
	"IDENTITY.AUTHORIZATION-CONSENT.REVOKED":                     true,
	"CUSTOMER.MERCHANT-INTEGRATION.SELLER-CONSENT-GRANTED":       true,
}

// PaypalWebhookVerifier::REQUIRED_HEADERS.
var paypalRequiredHeaders = []string{"Paypal-Transmission-Id", "Paypal-Transmission-Sig", "Paypal-Cert-Url", "Paypal-Auth-Algo", "Paypal-Transmission-Time"}

var (
	// errTokenCache marks a Redis failure, which rescue_from(*REDIS_TRANSPORT_ERRORS) answers.
	errTokenCache = errors.New("PayPal token cache")
	errNoCallSlot = errors.New("too many PayPal checks in flight")
)

// paypal is #paypal. Only a payload with an event_type is verified here; HandlePaypalEventWorker
// checks a legacy IPN with PayPal itself.
func (h *handlers) paypal(v *paypalVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		in, ok := h.begin(w, r, "paypal", maxBodyBytes)
		if !ok {
			return
		}
		if in.paramsErr != nil {
			h.stack.RenderParseError(w, r, in.paramsErr)
			return
		}
		logger := web.Logger(r)
		event := paypalPayload(in.req)
		if rails.Present(in.req.Param("event_type")) {
			err := v.verify(r.Context(), in.req, in.body, event)
			switch {
			case errors.Is(err, errNoCallSlot):
				logger.Warn("PayPal webhook checks are all busy")
				rails.Head(w, in.req, http.StatusServiceUnavailable)
				return
			case errors.Is(err, errTokenCache):
				logger.Error("Could not use the PayPal token cache", "error", err.Error())
				rails.Head(w, in.req, http.StatusServiceUnavailable)
				return
			case errors.Is(err, errRailsRaises):
				h.raise(in, "Error verifying PayPal webhook", err)
				return
			case err != nil:
				logger.Warn("Rejected PayPal webhook because signature validation failed", "reason", err.Error())
				rails.RenderJSON(w, in.req, http.StatusBadRequest, failureJSON)
				return
			}
		}
		if payload, err := sidekiq.Marshal(event); err == nil {
			logger.Info("PayPal event: received IPN/Webhook", "payload", string(payload))
		}
		delay := paypalDelay
		if eventType, _ := get(event, "event_type"); paypalImmediateEvents[stringOrEmpty(eventType)] {
			delay = 0
		}
		if h.push(in, paypalJob, delay, event, false) {
			rails.RenderJSON(w, in.req, http.StatusOK, successJSON)
		}
	}
}

// paypalPayload is params.to_unsafe_hash.except(:controller, :action, :format,
// :foreign_webhook).to_hash, which drops ParamsWrapper's copy too.
func paypalPayload(req *rails.Request) sidekiq.Hash {
	params := fromParams(req.Params).(sidekiq.Hash)
	payload := make(sidekiq.Hash, 0, len(params))
	for _, pair := range params {
		switch pair.Key {
		case "controller", "action", "format", wrapperKey:
		default:
			payload = append(payload, pair)
		}
	}
	return payload
}

func stringOrEmpty(v any) string {
	s, _ := v.(string)
	return s
}

// paypalVerifier ports PaypalWebhookVerifier#valid? and the PaypalPartnerRestCredentials
// token it sends.
type paypalVerifier struct {
	// PAYPAL_REST_ENDPOINT.
	api                               string
	webhookID, clientID, clientSecret string
	redis                             redis.Cmdable
	client                            *http.Client
	timeout, retryWait                time.Duration
	calls                             chan struct{}
}

func newPaypalVerifier(deps Deps) *paypalVerifier {
	if rails.Blank(deps.PaypalWebhookID) || rails.Blank(deps.PaypalPartnerClientID) || rails.Blank(deps.PaypalPartnerClientSecret) {
		return nil
	}
	api := "https://api.sandbox.paypal.com"
	if deps.Env.Name == "production" {
		api = "https://api.paypal.com"
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = paypalMaxCalls
	return &paypalVerifier{
		api: api, webhookID: deps.PaypalWebhookID, clientID: deps.PaypalPartnerClientID, clientSecret: deps.PaypalPartnerClientSecret,
		redis: deps.Redis, client: &http.Client{Transport: transport}, timeout: paypalVerifyTimeout, retryWait: paypalTokenRetryWait,
		calls: make(chan struct{}, paypalMaxCalls),
	}
}

// verify is nil when PayPal vouches for the event. An error wrapping errNoCallSlot,
// errTokenCache or errRailsRaises is one Rails doesn't answer with valid? returning false.
func (v *paypalVerifier) verify(ctx context.Context, req *rails.Request, body []byte, payload sidekiq.Hash) error {
	for _, name := range paypalRequiredHeaders {
		if rails.Blank(req.Header(name)) {
			return errors.New("missing " + name)
		}
	}
	select {
	case v.calls <- struct{}{}:
		defer func() { <-v.calls }()
	default:
		return errNoCallSlot
	}
	ctx, cancel := context.WithTimeout(ctx, v.timeout)
	defer cancel()
	// Ruby evaluates the headers, and so the token, before the body.
	token, err := v.token(ctx)
	if err != nil {
		return err
	}
	event, err := paypalWebhookEvent(body, payload)
	if err != nil {
		return err
	}
	request := rails.NewRHash().
		Sym("auth_algo", req.Header("Paypal-Auth-Algo")).
		Sym("cert_url", req.Header("Paypal-Cert-Url")).
		Sym("transmission_id", req.Header("Paypal-Transmission-Id")).
		Sym("transmission_sig", req.Header("Paypal-Transmission-Sig")).
		Sym("transmission_time", req.Header("Paypal-Transmission-Time")).
		Sym("webhook_id", v.webhookID).
		Sym("webhook_event", event)
	resp, err := v.send(ctx, "/v1/notifications/verify-webhook-signature", "application/json", rails.EncodeJSON(request), func(r *http.Request) {
		r.Header.Set("Authorization", token)
	})
	if err != nil {
		return err
	}
	answer, err := resp.object()
	if err != nil {
		return err
	}
	if status, _ := get(answer, "verification_status"); resp.status != http.StatusOK || status != "SUCCESS" {
		return fmt.Errorf("PayPal answered %d with verification_status %v", resp.status, status)
	}
	return nil
}

// paypalWebhookEvent is webhook_event: the body as JSON.parse reads it, or the params when
// the body is blank or doesn't parse.
func paypalWebhookEvent(body []byte, payload sidekiq.Hash) (any, error) {
	var event any = payload
	if !rails.Blank(string(body)) {
		parsed, loneLow, err := parseJSON(body)
		switch {
		case err == nil && loneLow:
			return nil, fmt.Errorf("%w: to_json refuses the body's unpaired low surrogate", errRailsRaises)
		case err == nil:
			event = parsed
		}
	}
	converted, ok := toActiveSupport(event)
	if !ok {
		return nil, errors.New("the params hold an upload")
	}
	return converted, nil
}

// toActiveSupport makes a value rails.EncodeJSON can take; ok is false for an upload. An
// integer past int64 comes out as a Float, where Ruby keeps its digits; PayPal sends
// none.
func toActiveSupport(v any) (any, bool) {
	switch v := v.(type) {
	case sidekiq.Hash:
		h := rails.NewRHash()
		for _, pair := range v {
			value, ok := toActiveSupport(pair.Value)
			if !ok {
				return nil, false
			}
			h.Str(pair.Key, value)
		}
		return h, true
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			value, ok := toActiveSupport(item)
			if !ok {
				return nil, false
			}
			out[i] = value
		}
		return out, true
	case rails.File:
		return nil, false
	}
	return v, true
}

// token is PaypalPartnerRestCredentials#auth_token: the cached header, or a new one.
func (v *paypalVerifier) token(ctx context.Context) (string, error) {
	cached, err := v.redis.Get(ctx, paypalTokenKey).Result()
	switch {
	case err == nil:
		return cached, nil
	case !errors.Is(err, redis.Nil):
		return "", fmt.Errorf("%w: %w", errTokenCache, err)
	}
	resp, err := v.requestToken(ctx)
	if err != nil {
		return "", err
	}
	fields, err := resp.object()
	if err != nil {
		return "", err
	}
	tokenType, _ := get(fields, "token_type")
	accessToken, _ := get(fields, "access_token")
	// Rails sends and caches whatever header these make; PayPal refuses one missing a part.
	if stringOrEmpty(tokenType) == "" || stringOrEmpty(accessToken) == "" {
		return "", fmt.Errorf("PayPal answered %d without a token", resp.status)
	}
	token := stringOrEmpty(tokenType) + " " + stringOrEmpty(accessToken)
	// Rails' EXPIRE of 0 or less deletes what it just set.
	expiresIn, _ := get(fields, "expires_in")
	if ttl, _ := rails.JSONToI(expiresIn); ttl > 0 {
		if err := v.redis.Set(ctx, paypalTokenKey, token, time.Duration(ttl)*time.Second).Err(); err != nil {
			return "", fmt.Errorf("%w: %w", errTokenCache, err)
		}
	}
	return token, nil
}

// requestToken is request_for_api_token: three tries, two seconds apart, while the request
// itself fails.
func (v *paypalVerifier) requestToken(ctx context.Context) (*paypalResponse, error) {
	for try := 1; ; try++ {
		resp, err := v.send(ctx, "/v1/oauth2/token", "application/x-www-form-urlencoded", "grant_type=client_credentials", func(r *http.Request) {
			r.SetBasicAuth(v.clientID, v.clientSecret)
			r.Header.Set("Accept", "application/json")
			r.Header.Set("Accept-Language", "en_US")
		})
		if err == nil || try == paypalTokenTries {
			return resp, err
		}
		select {
		case <-time.After(v.retryWait):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

type paypalResponse struct {
	status      int
	contentType string
	body        []byte
}

// send fails only when no answer arrives.
func (v *paypalVerifier) send(ctx context.Context, path, contentType, body string, edit func(*http.Request)) (*paypalResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.api+path, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	edit(req)
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, paypalMaxResponseBytes))
	if err != nil {
		return nil, err
	}
	return &paypalResponse{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: data}, nil
}

// HTTParty::Parser::SupportedFormats up to the last JSON one, in the order
// format_from_mimetype tries them against the Content-Type.
var httpartyFormats = []struct {
	mime string
	json bool
}{{"text/xml", false}, {"application/xml", false}, {"application/json", true}, {"application/vnd.api+json", true}, {"application/hal+json", true}, {"text/json", true}}

// object is HTTParty's parsed_response when it is a Hash. A nil, Array or scalar one makes
// the caller's ["field"] raise; a String yields no usable field.
func (r *paypalResponse) object() (sidekiq.Hash, error) {
	body := string(r.body)
	if body == "null" || strings.Trim(body, rails.RubySpace+"\x00") == "" {
		return nil, fmt.Errorf("%w: PayPal answered %d with an empty body", errRailsRaises, r.status)
	}
	isJSON := false
	for _, f := range httpartyFormats {
		if strings.Contains(r.contentType, f.mime) {
			isJSON = f.json
			break
		}
	}
	if !isJSON {
		return nil, fmt.Errorf("PayPal answered %d with %q", r.status, r.contentType)
	}
	parsed, _, err := parseJSON([]byte(strings.TrimPrefix(body, "\xef\xbb\xbf")))
	if err != nil {
		return nil, fmt.Errorf("PayPal answered %d with JSON that does not parse: %w", r.status, err)
	}
	switch parsed := parsed.(type) {
	case sidekiq.Hash:
		return parsed, nil
	case string:
		return nil, fmt.Errorf("PayPal answered %d with a JSON string", r.status)
	}
	return nil, fmt.Errorf("%w: PayPal answered %d with JSON that is not an object", errRailsRaises, r.status)
}
