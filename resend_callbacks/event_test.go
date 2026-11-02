package main

import (
	"encoding/json"
	"net/url"
	"reflect"
	"strings"
	"testing"
)

func buildTestEvent(body []byte, query url.Values, contentType string) (map[string]any, error) {
	return buildEvent(&requestBody{raw: body}, query, contentType, resendAction)
}

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
	event, err := buildTestEvent([]byte(body), url.Values{}, "application/json")
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
	event, err := buildTestEvent([]byte(`{"n":12345678901234567890,"f":1.50}`), nil, "application/json")
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
	event, err := buildTestEvent([]byte(`{"type":"email.opened","list":[1,null,2],"utf8":"✓"}`), url.Values{"type": {"from-query"}}, "application/json")
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

	array, err := buildTestEvent([]byte(`[1,2]`), nil, "application/json")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := array["_json"]; !ok {
		t.Error("a non-object body goes under _json")
	}

	if _, err := buildTestEvent([]byte(`{"a":1} {"b":2}`), nil, "application/json"); err == nil {
		t.Error("trailing data after the body was accepted")
	}
	if _, err := buildTestEvent([]byte(`{"a":`), nil, "application/json"); err == nil {
		t.Error("a truncated body was accepted")
	}
}

func TestBuildEventDoesNotWrapOverAnExistingKey(t *testing.T) {
	event, err := buildTestEvent([]byte(`{"foreign_webhook":"kept"}`), nil, "application/json")
	if err != nil {
		t.Fatal(err)
	}
	if event["foreign_webhook"] != "kept" {
		t.Fatalf("foreign_webhook = %v", event["foreign_webhook"])
	}
}

func TestBuildEventFollowsRailsContentTypeHandling(t *testing.T) {
	body := []byte(`{"type":"email.opened"}`)

	charset, err := buildTestEvent(body, nil, "application/json; charset=utf-8")
	if err != nil || charset["type"] != "email.opened" || charset[wrapperKey] == nil {
		t.Fatalf("a JSON content type with parameters is parsed and wrapped: %v %v", charset, err)
	}

	plain, err := buildTestEvent(body, nil, "text/plain")
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
		event, err := buildTestEvent(body, nil, contentType)
		if err != nil || event["type"] != "email.opened" || event[wrapperKey] == nil {
			t.Errorf("%q is JSON to Rails: %v %v", contentType, event, err)
		}
	}

	empty, err := buildTestEvent(nil, nil, "application/json")
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
		if _, err := buildTestEvent([]byte(body), nil, "application/json"); err == nil {
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
		if _, err := buildTestEvent([]byte(body), nil, "application/json"); err != nil {
			t.Errorf("%s: rejected a body Rails accepts: %v", name, err)
		}
	}
}

func TestParseJSONLikeRubyFollowsJSONParse(t *testing.T) {
	body := &requestBody{raw: []byte(`{"a":[1,null]}`)}
	value, err := body.parseRuby()
	if err != nil || body.unencodable() {
		t.Fatal(err)
	}
	if got, _ := json.Marshal(value); string(got) != `{"a":[1,null]}` {
		t.Errorf("JSON.parse keeps nils in arrays, got %s", got)
	}
	// json 2.13.2 keeps these as strings that are not UTF-8, for JSON.generate to refuse.
	for name, body := range map[string]string{"lone low surrogate": `{"s":"\udc00"}`, "invalid UTF-8": "{\"s\":\"\xff\"}"} {
		request := &requestBody{raw: []byte(body)}
		if _, err := request.parseRuby(); err != nil || !request.unencodable() {
			t.Errorf("%s: unencodable %v, err %v", name, request.unencodable(), err)
		}
	}
	for name, body := range map[string]string{"lone high surrogate": `{"s":"\ud800"}`, "low then high": `{"s":"\udc00\ud800"}`, "101 levels": strings.Repeat("[", 101) + "1" + strings.Repeat("]", 101)} {
		if _, err := (&requestBody{raw: []byte(body)}).parseRuby(); err == nil {
			t.Errorf("%s: accepted a body JSON.parse rejects", name)
		}
	}
}

func TestRailsRejectsOnlyJSONThatParses(t *testing.T) {
	cases := []struct {
		body, contentType string
		want              bool
	}{
		{"{\"s\":\"\xff\"}", "application/json", true},
		{`{"s":"\udc00"}`, "application/json; charset=utf-8", true},
		{"{\"s\":\"\xff\"}", "text/plain", false},
		{"{\"s\":\"\xff\"", "application/json", false},
		{`{"s":"\ud800"}`, "application/json", false},
		{`{"s":"ok"}`, "application/json", false},
	}
	for _, tc := range cases {
		if got := (&requestBody{raw: []byte(tc.body)}).railsRejects(tc.contentType); got != tc.want {
			t.Errorf("railsRejectsBody(%q, %q) = %v", tc.body, tc.contentType, got)
		}
	}
}
