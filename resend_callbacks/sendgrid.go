package main

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"time"
)

// ForeignWebhooksController::SENDGRID_WEBHOOK_PUBLIC_KEY_ENV_VARS, in order.
var sendgridPublicKeyEnvVars = []string{
	"SENDGRID_GR_CREATORS_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GR_CUSTOMERS_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GR_CUSTOMERS_LEVEL_2_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_WEBHOOK_PUBLIC_KEY",
	"SENDGRID_GUMROAD_TRANSACTIONS_WEBHOOK_PUBLIC_KEY",
}

const sendgridFlag = "verify_sendgrid_webhook_signatures"

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

// newSendgridVerifier takes the configured values in env-var order, blank ones
// already dropped.
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
	case blank(signature):
		return "Missing signature"
	case blank(timestamp):
		return "Missing timestamp"
	}
	sentAt := time.Unix(rubyToI(timestamp), 0)
	if diff := now.Sub(sentAt); diff > signatureTolerance || diff < -signatureTolerance {
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
