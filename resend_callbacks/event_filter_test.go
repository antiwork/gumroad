package main

import (
	"encoding/json"
	"testing"
)

// Encrypted with MailerInfo::Encryption's Ruby code, key "test-mailer-headers-key".
const (
	testHeaderKey        = "test-mailer-headers-key"
	encryptedClass       = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:h+gUekdefz6jt8vTeT+HqQ==" // CustomerMailer
	encryptedMethod      = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:VkXVqBR/0vu5iRFPm2ePxw==" // receipt
	encryptedPurchaseID  = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:pGZyZ3xtOWD0EmRZChakbw==" // 12345
	encryptedWorkflowIDs = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:Y1fu57SLZvB+3ciqxCUGdQ==" // [1,2]
	encryptedBadJSON     = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:FEeWKltdor0altcZvHfRxg==" // [1,
	encryptedBlank       = "v1:MDEyMzQ1Njc4OWFiY2RlZg==:CNHbkJ4yh0m9q99OD9CMfw==" // two spaces
)

// Resend's data.created_at format.
const testCreatedAt = "2026-10-14 18:19:14.140106+00"

func eventWithHeaders(eventType string, headers ...[2]string) map[string]any {
	list := make([]any, 0, len(headers))
	for _, h := range headers {
		list = append(list, map[string]any{"name": h[0], "value": h[1]})
	}
	return map[string]any{
		"type":       eventType,
		"created_at": "2026-10-14T18:19:15.254Z",
		"data": map[string]any{
			"created_at": testCreatedAt,
			"to":         []any{"buyer@example.com"},
			"headers":    list,
		},
	}
}

func TestEventFilterDecryptsWhatRailsEncrypts(t *testing.T) {
	filter := newEventFilter(testHeaderKey)
	for value, want := range map[string]string{encryptedClass: "CustomerMailer", encryptedMethod: "receipt", encryptedPurchaseID: "12345"} {
		got, err := filter.decrypt(value)
		if err != nil || string(got) != want {
			t.Errorf("decrypt(%q) = %q, %v; want %q", value, got, err, want)
		}
	}
}

func TestEventFilterKeepsTrackedEvents(t *testing.T) {
	filter := newEventFilter(testHeaderKey)
	event := eventWithHeaders("email.delivered",
		[2]string{"X-Gum-Mailer-Class", encryptedClass},
		[2]string{"x-gum-mailer-method", encryptedMethod},
		[2]string{"X-Gum-Purchase-Id", encryptedPurchaseID},
		[2]string{"X-Gum-Workflow-Ids", encryptedWorkflowIDs},
		[2]string{"X-Gum-Email-Provider", "resend"},
	)
	if !filter.trackable(event) {
		t.Fatal("a tracked event with mailer headers was dropped")
	}
}

func TestEventFilterDropsWhatResendEventInfoCallsInvalid(t *testing.T) {
	filter := newEventFilter(testHeaderKey)
	cases := map[string]map[string]any{
		"untracked type":       eventWithHeaders("email.sent", [2]string{"X-Gum-Mailer-Class", encryptedClass}, [2]string{"X-Gum-Mailer-Method", encryptedMethod}),
		"no mailer headers":    eventWithHeaders("email.opened"),
		"no mailer method":     eventWithHeaders("email.opened", [2]string{"X-Gum-Mailer-Class", encryptedClass}),
		"blank mailer method":  eventWithHeaders("email.opened", [2]string{"X-Gum-Mailer-Class", encryptedClass}, [2]string{"X-Gum-Mailer-Method", encryptedBlank}),
		"null headers":         {"type": "email.opened", "data": map[string]any{"to": []any{}, "created_at": testCreatedAt, "headers": nil}},
		"to as a single value": {"type": "email.opened", "data": map[string]any{"to": "buyer@example.com", "created_at": testCreatedAt}},
	}
	for name, event := range cases {
		if filter.trackable(event) {
			t.Errorf("%s: enqueued an event ResendEventInfo calls invalid", name)
		}
	}
}

// Wherever ResendEventInfo.new would raise, the controller's rescue enqueues instead.
func TestEventFilterEnqueuesWhatRailsCouldNotParse(t *testing.T) {
	filter := newEventFilter(testHeaderKey)
	untracked := func(headers ...[2]string) map[string]any { return eventWithHeaders("email.sent", headers...) }
	cases := map[string]map[string]any{
		"no data":              {"type": "email.sent"},
		"no recipients":        {"type": "email.sent", "data": map[string]any{"created_at": testCreatedAt}},
		"numeric created_at":   {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": 1}},
		"garbled created_at":   {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": "2026-13-45 99:99:99+00"}},
		"string click":         {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": testCreatedAt, "click": "link"}},
		"headers object":       {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": testCreatedAt, "headers": map[string]any{"a": "b"}}},
		"header without name":  {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": testCreatedAt, "headers": []any{map[string]any{"value": "v"}}}},
		"undecryptable header": untracked([2]string{"X-Gum-Charge-Id", "v1:not-base64:abc"}),
		"unknown key version":  untracked([2]string{"X-Gum-Mailer-Class", "v2:MDEyMzQ1Njc4OWFiY2RlZg==:h+gUekdefz6jt8vTeT+HqQ=="}),
		"plaintext header":     untracked([2]string{"X-Gum-Post-Id", "42"}),
		"numeric header value": {"type": "email.sent", "data": map[string]any{"to": []any{}, "created_at": testCreatedAt, "headers": []any{map[string]any{"name": "X-Gum-Post-Id", "value": json.Number("42")}}}},
		"bad workflow ids":     untracked([2]string{"X-Gum-Workflow-Ids", encryptedBadJSON}),
	}
	for name, event := range cases {
		if !filter.trackable(event) {
			t.Errorf("%s: dropped an event Rails would have enqueued", name)
		}
	}

	withoutKey := newEventFilter("")
	if !withoutKey.trackable(untracked([2]string{"X-Gum-Mailer-Class", encryptedClass})) {
		t.Error("without a key every encrypted header is undecryptable, so the event must be enqueued")
	}
}

func TestRubySplit(t *testing.T) {
	got := rubySplit(":a::b::", ":")
	want := []string{"", "a", "", "b"}
	if len(got) != len(want) {
		t.Fatalf("rubySplit = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("rubySplit = %q, want %q", got, want)
		}
	}
}
