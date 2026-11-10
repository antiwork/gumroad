package webhooks

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"net/http"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	sendgridFlag      = "verify_sendgrid_webhook_signatures"
	sendgridTolerance = 5 * time.Minute

	// ParamsWrapper's key for ForeignWebhooksController.
	wrapperKey = "foreign_webhook"
)

// ParamsWrapper::EXCLUDE_PARAMETERS.
var unwrappedParams = map[string]bool{"authenticity_token": true, "_method": true, "utf8": true}

// featureFlag is a flipper.Flag, or a test's stand-in.
type featureFlag interface {
	Active(ctx context.Context) (bool, error)
}

// sendgrid is #sendgrid: validate_sendgrid_webhook, then the action.
func (h *handlers) sendgrid(v *sendgridVerifier, flag featureFlag) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		in, ok := h.begin(w, r, "sendgrid", maxLargeBodyBytes)
		if !ok {
			return
		}
		signature := in.req.Header("X-Twilio-Email-Event-Webhook-Signature")
		timestamp := in.req.Header("X-Twilio-Email-Event-Webhook-Timestamp")
		if reason := v.verify(signature, timestamp, in.body, h.now()); reason != "" {
			logger := web.Logger(r)
			logger.Warn("SendGrid webhook verification failed: " + reason)
			ctx, cancel := context.WithTimeout(r.Context(), enqueueTimeout)
			enforced, err := flag.Active(ctx)
			cancel()
			switch {
			case err != nil && web.ClientLeft(w, r, err):
				return
			case err != nil:
				logger.Error("Could not read "+sendgridFlag, "error", err.Error())
				rails.Head(w, in.req, http.StatusServiceUnavailable)
				return
			case enforced:
				logger.Error("Error verifying SendGrid webhook: " + reason)
				rails.RenderJSON(w, in.req, http.StatusInternalServerError, failureJSON)
				return
			}
		}
		if in.paramsErr != nil {
			h.stack.RenderParseError(w, r, in.paramsErr)
			return
		}
		if h.push(in, sendgridJob, 0, sendgridParams(in.req), false) {
			rails.RenderJSON(w, in.req, http.StatusOK, successJSON)
		}
	}
}

// sendgridParams is params.to_unsafe_hash.to_hash: request.parameters, then
// ParamsWrapper's copy of request_parameters, which only JSON requests get.
func sendgridParams(req *rails.Request) sidekiq.Hash {
	params := fromParams(req.Params).(sidekiq.Hash)
	if _, taken := get(params, wrapperKey); req.ContentMimeType != "json" || taken {
		return params
	}
	body := fromParams(req.BodyParams).(sidekiq.Hash)
	wrapped := make(sidekiq.Hash, 0, len(body))
	for _, pair := range body {
		if !unwrappedParams[pair.Key] {
			wrapped = append(wrapped, pair)
		}
	}
	return append(params, sidekiq.Pair{Key: wrapperKey, Value: wrapped})
}

// A configured key, or the error OpenSSL::PKey::EC.new raises on it. Rails converts
// each key inside the any? loop, so a bad key fails the check only once reached.
type sendgridKey struct {
	key *ecdsa.PublicKey
	err error
}

// sendgridVerifier ports ForeignWebhooksController#verify_sendgrid_signature and
// sendgrid-ruby 6.7.0's SendGrid::EventWebhook.
type sendgridVerifier struct {
	keys []sendgridKey
}

// newSendgridVerifier takes the configured values in env-var order, blank ones dropped.
func newSendgridVerifier(encoded []string) *sendgridVerifier {
	v := &sendgridVerifier{}
	for _, value := range encoded {
		var k sendgridKey
		parsed, err := x509.ParsePKIXPublicKey(rubyDecode64(value))
		switch key, ok := parsed.(*ecdsa.PublicKey); {
		case err != nil:
			k.err = err
		case !ok:
			k.err = errors.New("not an EC public key")
		default:
			k.key = key
		}
		v.keys = append(v.keys, k)
	}
	return v
}

// verify returns Rails' failure message, or "" when the payload is signed.
func (v *sendgridVerifier) verify(signature, timestamp string, body []byte, now time.Time) string {
	switch {
	case len(v.keys) == 0:
		return "No public keys configured"
	case rails.Blank(signature):
		return "Missing signature"
	case rails.Blank(timestamp):
		return "Missing timestamp"
	}
	// Time.at(timestamp.to_i); a Bignum is too old by any measure.
	sentAt, ok := rails.StringToI(timestamp)
	if !ok {
		return "Timestamp too old"
	}
	if diff := now.Sub(time.Unix(sentAt, 0)); diff > sendgridTolerance || diff < -sendgridTolerance {
		return "Timestamp too old"
	}

	digest := sha256.New()
	digest.Write([]byte(timestamp))
	digest.Write(body)
	hash := digest.Sum(nil)
	decoded := rubyDecode64(signature)
	for _, k := range v.keys {
		if k.err != nil {
			return "Verification raised: " + k.err.Error()
		}
		if ecdsa.VerifyASN1(k.key, hash, decoded) {
			return ""
		}
	}
	return "Invalid signature"
}
