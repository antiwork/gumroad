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

// Rails' perform_async raises from JSON.generate on these, so the request fails with a 500.
func TestJobPayloadRefusesWhatSidekiqCannotSerialize(t *testing.T) {
	nested := func(n int) any {
		var v any = []any{}
		for range n - 1 {
			v = []any{v}
		}
		return v
	}
	now := time.Unix(1792001956, 0)
	if _, err := newJobPayload(map[string]any{"a": nested(97)}, now); err != nil {
		t.Errorf("a job 100 levels deep failed: %v", err)
	}
	if _, err := newJobPayload(map[string]any{"a": nested(98)}, now); err == nil {
		t.Error("a job 101 levels deep was accepted")
	}
	if _, err := newJobPayload(map[string]any{"n": json.Number("1e400")}, now); err == nil {
		t.Error("a number Ruby reads as Infinity was accepted")
	}
	if _, err := newJobPayload(map[string]any{"n": json.Number("1e-400")}, now); err != nil {
		t.Errorf("an underflowing number failed: %v", err)
	}
}
