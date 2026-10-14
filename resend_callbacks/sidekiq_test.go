package main

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestJobPayloadMatchesWhatSidekiqClientPushes(t *testing.T) {
	now := time.Unix(1792001956, 315285000)
	payload, err := newJobPayload(map[string]any{"from": `"Seller" <seller@example.com>`}, now)
	if err != nil {
		t.Fatal(err)
	}

	// Key order as Rails pushes it: retry, queue, backtrace, args, class, jid, created_at, enqueued_at.
	prefix := `{"retry":5,"queue":"low","backtrace":true,"args":[{"from":"\"Seller\" <seller@example.com>"}],"class":"HandleResendEventJob","jid":"`
	if !strings.HasPrefix(string(payload), prefix) {
		t.Fatalf("payload = %s", payload)
	}
	if !strings.HasSuffix(string(payload), `,"created_at":1792001956.315285,"enqueued_at":1792001956.315285}`) {
		t.Fatalf("payload = %s", payload)
	}

	var job sidekiqJob
	if err := json.Unmarshal(payload, &job); err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`\A[0-9a-f]{24}\z`).MatchString(job.JID) {
		t.Fatalf("jid = %q, want SecureRandom.hex(12)", job.JID)
	}
}
