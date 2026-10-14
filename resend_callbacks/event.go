package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"net/url"
	"slices"
)

// The ParamsWrapper key Rails adds for ForeignWebhooksController.
const wrapperKey = "foreign_webhook"

// ParamsWrapper leaves these out of the wrapped copy.
var unwrappedParams = map[string]bool{"authenticity_token": true, "_method": true, "utf8": true}

// buildEvent rebuilds `params.to_unsafe_hash` as ForeignWebhooksController#resend
// passes it to HandleResendEventJob: the JSON body (non-object bodies under "_json"),
// query parameters over it, the route's controller and action, and ParamsWrapper's
// copy of the body under "foreign_webhook". Resend always posts application/json.
func buildEvent(body []byte, query url.Values) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var parsed any
	if err := decoder.Decode(&parsed); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("unexpected data after the JSON body")
	}
	parsed = compactNils(parsed)

	request, ok := parsed.(map[string]any)
	if !ok {
		request = map[string]any{"_json": parsed}
	}

	event := maps.Clone(request)
	for key, values := range query {
		event[key] = values[len(values)-1]
	}
	event["controller"] = "foreign_webhooks"
	event["action"] = "resend"

	if _, taken := event[wrapperKey]; !taken {
		wrapped := maps.Clone(request)
		maps.DeleteFunc(wrapped, func(key string, _ any) bool { return unwrappedParams[key] })
		event[wrapperKey] = wrapped
	}
	return event, nil
}

// compactNils mirrors Rails' deep munge, which drops nil elements from parameter arrays.
func compactNils(value any) any {
	switch v := value.(type) {
	case map[string]any:
		for key, item := range v {
			v[key] = compactNils(item)
		}
		return v
	case []any:
		kept := slices.DeleteFunc(v, func(item any) bool { return item == nil })
		for i, item := range kept {
			kept[i] = compactNils(item)
		}
		return kept
	default:
		return v
	}
}
