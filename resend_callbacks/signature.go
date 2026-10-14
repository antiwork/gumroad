package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const signatureTolerance = 5 * time.Minute

// signatureVerifier checks Resend's Svix webhook signatures, matching
// ForeignWebhooksController#validate_resend_webhook.
type signatureVerifier struct {
	secret []byte
}

func newSignatureVerifier(secret string) (*signatureVerifier, error) {
	if blank(secret) {
		return nil, errors.New("RESEND_WEBHOOK_SECRET is not set")
	}
	// Rails decodes everything after the first underscore, i.e. the part after "whsec_".
	if _, after, found := strings.Cut(secret, "_"); found {
		secret = after
	}
	key, err := base64.StdEncoding.DecodeString(secret)
	if err != nil {
		return nil, fmt.Errorf("RESEND_WEBHOOK_SECRET is not base64: %w", err)
	}
	return &signatureVerifier{secret: key}, nil
}

func (v *signatureVerifier) verify(header http.Header, body []byte, now time.Time) error {
	signatures := header.Get("svix-signature")
	timestamp := header.Get("svix-timestamp")
	messageID := header.Get("svix-id")
	switch {
	case blank(signatures):
		return errors.New("Missing signature")
	case blank(timestamp):
		return errors.New("Missing timestamp")
	case blank(messageID):
		return errors.New("Missing message ID")
	}

	sentAt := time.Unix(rubyToI(timestamp), 0)
	if diff := now.Sub(sentAt); diff > signatureTolerance || diff < -signatureTolerance {
		return errors.New("Timestamp too old")
	}

	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(messageID + "." + timestamp + "."))
	mac.Write(body)
	expected := []byte(base64.StdEncoding.EncodeToString(mac.Sum(nil)))

	// Svix sends space-separated "v1,<signature>" pairs and several of them while a
	// secret rotates. Rails compared only the first; any matching v1 entry is valid.
	sawSignature := false
	for _, entry := range strings.Fields(signatures) {
		version, signature, found := strings.Cut(entry, ",")
		if !found || signature == "" || version != "v1" {
			continue
		}
		sawSignature = true
		if hmac.Equal([]byte(signature), expected) {
			return nil
		}
	}
	if !sawSignature {
		return errors.New("Invalid signature format")
	}
	return errors.New("Invalid signature")
}
