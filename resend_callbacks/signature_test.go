package main

import (
	"net/http"
	"testing"
	"time"
)

// Generated with ForeignWebhooksController#validate_resend_webhook's Ruby code.
const (
	testWebhookSecret = "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
	testMessageID     = "msg_2Lh9KRb0pzN4hDUM4ZD9Ht5bG9M"
	testTimestamp     = "1792001956"
	testPayload       = `{"type":"email.delivered","created_at":"2026-10-14T18:19:15.254Z","data":{"to":["a@example.com"],"headers":[]}}`
	testSignature     = "wXfDGWL9gDU4YYzrJxo19ad7jnJvTgaLfFeulJvMWEU="
)

var testSignedAt = time.Unix(1792001956, 0)

func signedHeader(signature string) http.Header {
	header := http.Header{}
	header.Set("svix-id", testMessageID)
	header.Set("svix-timestamp", testTimestamp)
	header.Set("svix-signature", signature)
	return header
}

func TestSignatureVerifierAcceptsTheSignatureRailsComputes(t *testing.T) {
	verifier, err := newSignatureVerifier(testWebhookSecret)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifier.verify(signedHeader("v1,"+testSignature), []byte(testPayload), testSignedAt.Add(4*time.Minute)); err != nil {
		t.Fatalf("verify() = %v, want nil", err)
	}
}

func TestSignatureVerifierAcceptsAnyMatchingSignatureDuringRotation(t *testing.T) {
	verifier, _ := newSignatureVerifier(testWebhookSecret)
	header := signedHeader("v1,b2xkLXNlY3JldA== v1," + testSignature)
	if err := verifier.verify(header, []byte(testPayload), testSignedAt); err != nil {
		t.Fatalf("verify() = %v, want nil", err)
	}
}

func TestSignatureVerifierRejections(t *testing.T) {
	verifier, _ := newSignatureVerifier(testWebhookSecret)
	cases := map[string]struct {
		header http.Header
		body   string
		now    time.Time
		want   string
	}{
		"tampered body":        {signedHeader("v1," + testSignature), testPayload + " ", testSignedAt, "Invalid signature"},
		"stale timestamp":      {signedHeader("v1," + testSignature), testPayload, testSignedAt.Add(6 * time.Minute), "Timestamp too old"},
		"future timestamp":     {signedHeader("v1," + testSignature), testPayload, testSignedAt.Add(-6 * time.Minute), "Timestamp too old"},
		"no version prefix":    {signedHeader(testSignature), testPayload, testSignedAt, "Invalid signature format"},
		"missing signature":    {signedHeader(""), testPayload, testSignedAt, "Missing signature"},
		"unknown version only": {signedHeader("v2," + testSignature), testPayload, testSignedAt, "Invalid signature format"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			err := verifier.verify(tc.header, []byte(tc.body), tc.now)
			if err == nil || err.Error() != tc.want {
				t.Fatalf("verify() = %v, want %q", err, tc.want)
			}
		})
	}

	header := signedHeader("v1," + testSignature)
	header.Del("svix-id")
	if err := verifier.verify(header, []byte(testPayload), testSignedAt); err == nil || err.Error() != "Missing message ID" {
		t.Fatalf("verify() without svix-id = %v", err)
	}
}

func TestNewSignatureVerifierRequiresASecret(t *testing.T) {
	if _, err := newSignatureVerifier(""); err == nil {
		t.Fatal("newSignatureVerifier(\"\") succeeded")
	}
}

func TestRubyToI(t *testing.T) {
	cases := map[string]int64{"1792001956": 1792001956, " 42abc": 42, "-7": -7, "1_000": 1000, "1__0": 1, "abc": 0, "": 0}
	for input, want := range cases {
		if got := rubyToI(input); got != want {
			t.Errorf("rubyToI(%q) = %d, want %d", input, got, want)
		}
	}
}
