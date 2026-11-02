package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Stripe::Webhook::DEFAULT_TOLERANCE.
const stripeTolerance = 300 * time.Second

// stripeVerifier ports Stripe::Webhook::Signature.verify_header (stripe 12.5.0).
type stripeVerifier struct {
	secret []byte
}

func newStripeVerifier(secret string) *stripeVerifier {
	if blank(secret) {
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
			item = strings.TrimLeft(item, rubySpace)
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

// stripeAsJSON mirrors Stripe::Event#as_json under ActiveSupport: keys are already
// strings, nils stay in arrays, and a Float that overflowed to Infinity becomes nil.
func stripeAsJSON(value any) any {
	switch v := value.(type) {
	case map[string]any:
		for key, item := range v {
			v[key] = stripeAsJSON(item)
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

func acceptStripeEvent(event map[string]any) bool {
	id := event["id"]
	return id != nil && id != false
}

func acceptStripeConnectEvent(event map[string]any) bool {
	return present(event["id"]) && (present(event["account"]) || present(event["user_id"]))
}

// present mirrors Object#present? on a parsed value. A StripeObject doesn't respond
// to empty?, so even an empty object is present.
func present(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return strings.TrimSpace(v) != ""
	case []any:
		return len(v) > 0
	default:
		return true
	}
}
