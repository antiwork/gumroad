package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// The ParamsWrapper key Rails adds for ForeignWebhooksController.
const wrapperKey = "foreign_webhook"

// ParamsWrapper leaves these out of the wrapped copy.
var unwrappedParams = map[string]bool{"authenticity_token": true, "_method": true, "utf8": true}

// Mime[:json] and its synonyms in Rails 8.1.
var jsonMediaTypes = map[string]bool{
	"application/json":         true,
	"text/x-json":              true,
	"application/jsonrequest":  true,
	"application/problem+json": true,
}

// Ruby's JSON max_nesting, for both JSON.parse and JSON.generate.
const maxNesting = 100

// buildEvent rebuilds `params.to_unsafe_hash` as ForeignWebhooksController#resend
// passes it to HandleResendEventJob: the JSON body (non-object bodies under "_json"),
// query parameters over it, the route's controller and action, and ParamsWrapper's
// copy of the body under "foreign_webhook", which Rails only adds to JSON requests.
// A non-JSON body is ignored; Rails would parse a form body, which Resend never sends.
func buildEvent(body []byte, query url.Values, contentType string) (map[string]any, error) {
	isJSON := jsonMediaTypes[railsMediaType(contentType)]

	request := map[string]any{}
	if isJSON && len(body) > 0 {
		parsed, err := parseJSONLikeRails(body)
		if err != nil {
			return nil, err
		}
		if object, ok := parsed.(map[string]any); ok {
			request = object
		} else {
			request = map[string]any{"_json": parsed}
		}
	}

	event := maps.Clone(request)
	for key, values := range query {
		event[key] = values[len(values)-1]
	}
	event["controller"] = "foreign_webhooks"
	event["action"] = "resend"

	if _, taken := event[wrapperKey]; isJSON && !taken {
		wrapped := maps.Clone(request)
		maps.DeleteFunc(wrapped, func(key string, _ any) bool { return unwrappedParams[key] })
		event[wrapperKey] = wrapped
	}
	return event, nil
}

// railsMediaType mirrors Request#content_mime_type: everything before the first ',' or
// ';', stripped and downcased.
func railsMediaType(contentType string) string {
	if i := strings.IndexAny(contentType, ",;"); i >= 0 {
		contentType = contentType[:i]
	}
	return strings.ToLower(strings.TrimSpace(contentType))
}

// parseJSONLikeRails decodes a body as ActiveSupport::JSON.decode and Rails' param
// builder do, rejecting what they reject and dropping nils from arrays. Ruby also
// accepts JSON comments and unknown escapes; Go rejects those, and Resend sends neither.
func parseJSONLikeRails(body []byte) (any, error) {
	if !utf8.Valid(body) {
		return nil, errors.New("invalid UTF-8 in the JSON body")
	}
	if hasLoneSurrogate(body) {
		return nil, errors.New("unpaired surrogate escape in the JSON body")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var parsed any
	if err := decoder.Decode(&parsed); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("unexpected data after the JSON body")
	}
	return normalizeParams(parsed, 1)
}

// normalizeParams mirrors Ruby's parser limit and Rails' deep munge: a non-empty array
// or object nested deeper than max_nesting is an error, and nils are dropped from arrays.
func normalizeParams(value any, depth int) (any, error) {
	switch v := value.(type) {
	case map[string]any:
		if len(v) > 0 && depth > maxNesting {
			return nil, errors.New("JSON body nested too deeply")
		}
		for key, item := range v {
			normalized, err := normalizeParams(item, depth+1)
			if err != nil {
				return nil, err
			}
			v[key] = normalized
		}
		return v, nil
	case []any:
		if len(v) > 0 && depth > maxNesting {
			return nil, errors.New("JSON body nested too deeply")
		}
		v = slices.DeleteFunc(v, func(item any) bool { return item == nil })
		for i, item := range v {
			normalized, err := normalizeParams(item, depth+1)
			if err != nil {
				return nil, err
			}
			v[i] = normalized
		}
		return v, nil
	default:
		return v, nil
	}
}

// hasLoneSurrogate reports a \uD800-\uDFFF escape that isn't part of a high-low pair.
// Ruby's parser rejects an unpaired high surrogate, and Rails rejects the invalid
// UTF-8 an unpaired low one decodes to; Go would substitute U+FFFD for either. Valid
// JSON only has backslashes inside strings, so there's no need to track quotes.
func hasLoneSurrogate(body []byte) bool {
	for i := 0; i < len(body); i++ {
		if body[i] != '\\' {
			continue
		}
		code, ok := hexEscape(body, i)
		if !ok {
			i++ // skip the escaped character, which may itself be a backslash
			continue
		}
		if utf16.IsSurrogate(code) {
			low, _ := hexEscape(body, i+6)
			if utf16.DecodeRune(code, low) == unicode.ReplacementChar {
				return true
			}
			i += 6
		}
		i += 5
	}
	return false
}

// hexEscape reads the \uXXXX escape starting at body[i].
func hexEscape(body []byte, i int) (rune, bool) {
	if i+6 > len(body) || body[i] != '\\' || body[i+1] != 'u' {
		return 0, false
	}
	code, err := strconv.ParseUint(string(body[i+2:i+6]), 16, 16)
	return rune(code), err == nil
}
