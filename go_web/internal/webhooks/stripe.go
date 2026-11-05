package webhooks

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// Stripe::Webhook::DEFAULT_TOLERANCE.
const stripeTolerance = 300 * time.Second

// stripe is #stripe and #stripe_connect: validate_stripe_webhook, then the action.
func (h *handlers) stripe(v *stripeVerifier, action string, accept func(sidekiq.Hash) bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		in, ok := h.begin(w, r, action, maxLargeBodyBytes)
		if !ok {
			return
		}
		if err := v.verify(in.req.Header("Stripe-Signature"), in.body, h.now()); err != nil {
			if errors.Is(err, errRailsRaises) {
				h.raise(in, "Error verifying Stripe webhook", err)
			} else {
				rails.RenderJSON(w, in.req, http.StatusBadRequest, failureJSON)
			}
			return
		}
		parsed, loneLow, err := parseJSON(in.body)
		if err != nil {
			rails.RenderJSON(w, in.req, http.StatusBadRequest, failureJSON)
			return
		}
		event, isObject := parsed.(sidekiq.Hash)
		if !isObject {
			// Stripe::Event.construct_from raises on anything but an object.
			h.raise(in, "Stripe webhook body is not an object", errRailsRaises)
			return
		}
		// The controller tests the StripeObject, before as_json turns Infinity into nil.
		if !accept(event) {
			rails.RenderJSON(w, in.req, http.StatusOK, failureJSON)
			return
		}
		if h.push(in, stripeJob, 0, stripeAsJSON(event), loneLow) {
			rails.RenderJSON(w, in.req, http.StatusOK, successJSON)
		}
	}
}

func acceptStripeEvent(event sidekiq.Hash) bool {
	id, _ := get(event, "id")
	return rails.Truthy(id)
}

// A StripeObject has no empty?, so rails.Present counts even an empty object.
func acceptStripeConnectEvent(event sidekiq.Hash) bool {
	id, _ := get(event, "id")
	account, _ := get(event, "account")
	userID, _ := get(event, "user_id")
	return rails.Present(id) && (rails.Present(account) || rails.Present(userID))
}

// stripeVerifier ports Stripe::Webhook::Signature.verify_header (stripe 12.5.0).
type stripeVerifier struct {
	secret []byte
}

func newStripeVerifier(secret string) *stripeVerifier {
	if rails.Blank(secret) {
		return nil
	}
	return &stripeVerifier{secret: []byte(secret)}
}

func (v *stripeVerifier) verify(header string, body []byte, now time.Time) error {
	timestamp, signatures, ok := parseStripeHeader(header)
	if !ok {
		return errors.New("Unable to extract timestamp and signatures from header")
	}
	if len(signatures) == 0 {
		return errors.New("No signatures found with expected scheme v1")
	}

	var digits [20]byte
	var sum [sha256.Size]byte
	var expected [2 * sha256.Size]byte
	mac := hmac.New(sha256.New, v.secret)
	mac.Write(strconv.AppendInt(digits[:0], timestamp, 10))
	mac.Write([]byte("."))
	mac.Write(body)
	hex.AppendEncode(expected[:0], mac.Sum(sum[:0]))

	matched := false
	for _, signature := range signatures {
		// A bare "v1" entry is a nil signature, which Util.secure_compare raises on.
		if signature == nil {
			return fmt.Errorf("%w: v1 entry without a value", errRailsRaises)
		}
		if hmac.Equal(expected[:], []byte(*signature)) {
			matched = true
			break
		}
	}
	if !matched {
		return errors.New("No signatures found matching the expected signature for payload")
	}
	// Only the past is bounded; a future timestamp passes.
	if time.Unix(timestamp, 0).Before(now.Add(-stripeTolerance)) {
		return errors.New("Timestamp outside the tolerance zone")
	}
	return nil
}

// parseStripeHeader mirrors get_timestamp_and_signatures: the header splits on
// /,\s*/, the first "t" entry is the timestamp, read with Integer(), and every "v1"
// entry is a signature.
func parseStripeHeader(header string) (int64, []*string, bool) {
	var timestamp *string
	sawTimestamp := false
	var signatures []*string
	for i, item := range strings.Split(header, ",") {
		if i > 0 {
			item = strings.TrimLeft(item, rails.RubySpace)
		}
		// String#split drops trailing empty fields, and "".split("=", 2) is [].
		if item == "" {
			continue
		}
		key, value, hasValue := strings.Cut(item, "=")
		var v *string
		if hasValue {
			v = &value
		}
		switch {
		case key == "t" && !sawTimestamp:
			sawTimestamp, timestamp = true, v
		case key == "v1":
			signatures = append(signatures, v)
		}
	}
	if timestamp == nil {
		return 0, nil, false
	}
	t, ok := rubyInteger(*timestamp)
	return t, signatures, ok
}

// stripeAsJSON is Stripe::Event#as_json under ActiveSupport. Every object becomes a
// StripeObject, which StripeObject.new(values[:id]) starts with a truthy id; a Float
// that overflowed to Infinity becomes nil.
func stripeAsJSON(value any) any {
	switch v := value.(type) {
	case sidekiq.Hash:
		if i := pairIndex(v, "id"); i > 0 && rails.Truthy(v[i].Value) {
			id := v[i]
			copy(v[1:i+1], v[:i])
			v[0] = id
		}
		for i := range v {
			v[i].Value = stripeAsJSON(v[i].Value)
		}
	case []any:
		for i, item := range v {
			v[i] = stripeAsJSON(item)
		}
	case json.Number:
		if rubyInfinity(v) {
			return nil
		}
	}
	return value
}
