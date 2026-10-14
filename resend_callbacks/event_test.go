package main

import (
	"encoding/json"
	"net/url"
	"reflect"
	"strings"
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
	event, err := buildEvent([]byte(body), url.Values{}, "application/json")
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
	event, err := buildEvent([]byte(`{"n":12345678901234567890,"f":1.50}`), nil, "application/json")
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
	event, err := buildEvent([]byte(`{"type":"email.opened","list":[1,null,2],"utf8":"✓"}`), url.Values{"type": {"from-query"}}, "application/json")
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

	array, err := buildEvent([]byte(`[1,2]`), nil, "application/json")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := array["_json"]; !ok {
		t.Error("a non-object body goes under _json")
	}

	if _, err := buildEvent([]byte(`{"a":1} {"b":2}`), nil, "application/json"); err == nil {
		t.Error("trailing data after the body was accepted")
	}
	if _, err := buildEvent([]byte(`{"a":`), nil, "application/json"); err == nil {
		t.Error("a truncated body was accepted")
	}
}

func TestBuildEventDoesNotWrapOverAnExistingKey(t *testing.T) {
	event, err := buildEvent([]byte(`{"foreign_webhook":"kept"}`), nil, "application/json")
	if err != nil {
		t.Fatal(err)
	}
	if event["foreign_webhook"] != "kept" {
		t.Fatalf("foreign_webhook = %v", event["foreign_webhook"])
	}
}

func TestBuildEventFollowsRailsContentTypeHandling(t *testing.T) {
	body := []byte(`{"type":"email.opened"}`)

	charset, err := buildEvent(body, nil, "application/json; charset=utf-8")
	if err != nil || charset["type"] != "email.opened" || charset[wrapperKey] == nil {
		t.Fatalf("a JSON content type with parameters is parsed and wrapped: %v %v", charset, err)
	}

	plain, err := buildEvent(body, nil, "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	if _, parsed := plain["type"]; parsed {
		t.Error("Rails does not parse a non-JSON body into params")
	}
	if _, wrapped := plain[wrapperKey]; wrapped {
		t.Error("ParamsWrapper only wraps JSON requests")
	}

	for _, contentType := range []string{"application/problem+json", "application/json, text/plain", "application/json; a=1; a=2", " APPLICATION/JSON "} {
		event, err := buildEvent(body, nil, contentType)
		if err != nil || event["type"] != "email.opened" || event[wrapperKey] == nil {
			t.Errorf("%q is JSON to Rails: %v %v", contentType, event, err)
		}
	}

	empty, err := buildEvent(nil, nil, "application/json")
	if err != nil {
		t.Fatal(err)
	}
	if wrapped, ok := empty[wrapperKey].(map[string]any); !ok || len(wrapped) != 0 {
		t.Errorf("an empty JSON request still gets an empty wrapper, got %v", empty)
	}
}

func TestBuildEventRejectsWhatRailsRejects(t *testing.T) {
	deep := func(n int, inner string) string {
		return strings.Repeat("[", n) + inner + strings.Repeat("]", n)
	}
	rejected := map[string]string{
		"invalid UTF-8":          "{\"s\":\"\xff\"}",
		"lone high surrogate":    `{"s":"\ud800"}`,
		"lone low surrogate":     `{"s":"\udc00x"}`,
		"101 non-empty levels":   deep(101, "1"),
		"NaN":                    `{"n":NaN}`,
		"high then other escape": `{"s":"\ud800\u0041"}`,
	}
	for name, body := range rejected {
		if _, err := buildEvent([]byte(body), nil, "application/json"); err == nil {
			t.Errorf("%s: accepted a body Rails rejects", name)
		}
	}
	accepted := map[string]string{
		"surrogate pair":           `{"s":"\ud83d\ude00"}`,
		"escaped backslash then u": `{"s":"\\ud800"}`,
		"100 non-empty levels":     deep(100, "1"),
		"empty array at level 101": deep(101, ""),
		"float underflow":          `{"n":1e-400}`,
		"big integer":              `{"n":123456789012345678901234567890}`,
	}
	for name, body := range accepted {
		if _, err := buildEvent([]byte(body), nil, "application/json"); err != nil {
			t.Errorf("%s: rejected a body Rails accepts: %v", name, err)
		}
	}
}
