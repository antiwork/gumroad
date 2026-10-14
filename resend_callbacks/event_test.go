package main

import (
	"encoding/json"
	"net/url"
	"reflect"
	"testing"
)

func decodeJSON(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func roundTrip(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return decodeJSON(t, string(b))
}

// The shape of a HandleResendEventJob argument enqueued by Rails in production.
func TestBuildEventMatchesRailsParams(t *testing.T) {
	body := `{"created_at":"2026-10-14T18:19:15.254Z","data":{"to":["a@example.com"],"headers":[{"name":"X-Gum-Email-Provider","value":"resend"}]},"type":"email.bounced"}`
	event, err := buildEvent([]byte(body), url.Values{})
	if err != nil {
		t.Fatal(err)
	}
	want := decodeJSON(t, `{
		"created_at":"2026-10-14T18:19:15.254Z",
		"data":{"to":["a@example.com"],"headers":[{"name":"X-Gum-Email-Provider","value":"resend"}]},
		"type":"email.bounced",
		"controller":"foreign_webhooks",
		"action":"resend",
		"foreign_webhook":{
			"created_at":"2026-10-14T18:19:15.254Z",
			"data":{"to":["a@example.com"],"headers":[{"name":"X-Gum-Email-Provider","value":"resend"}]},
			"type":"email.bounced"
		}
	}`)
	if got := roundTrip(t, event); !reflect.DeepEqual(got, want) {
		t.Fatalf("buildEvent = %v\nwant %v", got, want)
	}
}

func TestBuildEventKeepsNumbersAsSent(t *testing.T) {
	event, err := buildEvent([]byte(`{"n":12345678901234567890,"f":1.50}`), nil)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{"n": "12345678901234567890", "f": "1.50"} {
		if got, _ := json.Marshal(event[key]); string(got) != want {
			t.Errorf("%s = %s, want %s", key, got, want)
		}
	}
}

func TestBuildEventFollowsRailsParameterRules(t *testing.T) {
	event, err := buildEvent([]byte(`{"type":"email.opened","list":[1,null,2],"utf8":"✓"}`), url.Values{"type": {"from-query"}})
	if err != nil {
		t.Fatal(err)
	}
	got := roundTrip(t, event).(map[string]any)
	if got["type"] != "from-query" {
		t.Errorf("query parameters override the body in Rails, got type %v", got["type"])
	}
	if !reflect.DeepEqual(got["list"], []any{1.0, 2.0}) {
		t.Errorf("deep munge drops nils from arrays, got %v", got["list"])
	}
	wrapped := got["foreign_webhook"].(map[string]any)
	if _, ok := wrapped["utf8"]; ok {
		t.Error("ParamsWrapper excludes utf8 from the wrapped copy")
	}
	if wrapped["type"] != "email.opened" {
		t.Errorf("the wrapped copy is the body only, got type %v", wrapped["type"])
	}

	array, err := buildEvent([]byte(`[1,2]`), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := array["_json"]; !ok {
		t.Error("a non-object body goes under _json")
	}

	if _, err := buildEvent([]byte(`{"a":1} {"b":2}`), nil); err == nil {
		t.Error("trailing data after the body was accepted")
	}
	if _, err := buildEvent([]byte(`{"a":`), nil); err == nil {
		t.Error("a truncated body was accepted")
	}
}

func TestBuildEventDoesNotWrapOverAnExistingKey(t *testing.T) {
	event, err := buildEvent([]byte(`{"foreign_webhook":"kept"}`), nil)
	if err != nil {
		t.Fatal(err)
	}
	if event["foreign_webhook"] != "kept" {
		t.Fatalf("foreign_webhook = %v", event["foreign_webhook"])
	}
}
