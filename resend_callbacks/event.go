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

// The action names buildEvent stores, boxed once.
var (
	resendAction   any = "resend"
	sendgridAction any = "sendgrid"
)

// buildEvent rebuilds the action's `params.to_unsafe_hash`: the JSON body (non-objects
// under "_json"), query parameters over it, controller and action, and ParamsWrapper's
// "foreign_webhook" copy for JSON requests. Form bodies, which no sender posts, are ignored.
func buildEvent(body *requestBody, query url.Values, contentType string, action any) (map[string]any, error) {
	isJSON := isJSONContentType(contentType)

	request := map[string]any{}
	if isJSON && len(body.raw) > 0 {
		parsed, err := body.parseRails()
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
	event["action"] = action

	if _, taken := event[wrapperKey]; isJSON && !taken {
		wrapped := maps.Clone(request)
		maps.DeleteFunc(wrapped, func(key string, _ any) bool { return unwrappedParams[key] })
		event[wrapperKey] = wrapped
	}
	return event, nil
}

func isJSONContentType(contentType string) bool {
	return jsonMediaTypes[railsMediaType(contentType)]
}

// railsMediaType mirrors Request#content_mime_type: everything before the first ',' or
// ';', stripped and downcased.
func railsMediaType(contentType string) string {
	if i := strings.IndexAny(contentType, ",;"); i >= 0 {
		contentType = contentType[:i]
	}
	return strings.ToLower(strings.TrimSpace(contentType))
}

// requestBody is a request body whose encoding scan the parsers and ActionDispatch's
// check share.
type requestBody struct {
	raw               []byte
	scanned           bool
	loneHigh, loneLow bool
	validUTF8         bool
}

func (b *requestBody) scan() {
	if !b.scanned {
		b.loneHigh, b.loneLow = unpairedSurrogates(b.raw)
		b.validUTF8 = utf8.Valid(b.raw)
		b.scanned = true
	}
}

// unencodable reports a string Ruby's parser keeps but JSON.generate refuses: invalid
// UTF-8 or an unpaired low surrogate.
func (b *requestBody) unencodable() bool {
	b.scan()
	return b.loneLow || !b.validUTF8
}

// parseRuby decodes as JSON.parse (json 2.13.2) does. Ruby also accepts comments and
// unknown escapes, which Go rejects and no sender sends.
func (b *requestBody) parseRuby() (any, error) {
	return b.parse(false)
}

// parseRails decodes as ActiveSupport::JSON.decode and Rails' param builder do: anything
// that isn't UTF-8 is rejected, and deep munge drops nils from arrays.
func (b *requestBody) parseRails() (any, error) {
	if b.unencodable() {
		return nil, errors.New("invalid UTF-8 in the JSON body")
	}
	return b.parse(true)
}

func (b *requestBody) parse(munge bool) (any, error) {
	if b.scan(); b.loneHigh {
		return nil, errors.New("unpaired high surrogate escape in the JSON body")
	}
	decoder := json.NewDecoder(bytes.NewReader(b.raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("unexpected data after the JSON body")
	}
	return normalizeJSON(value, 1, munge)
}

// railsRejects reports a JSON request body ActionDispatch answers with a 400 before any
// controller callback runs: one that parses but isn't UTF-8. A body that doesn't parse
// is left to the action, as Rails leaves it.
func (b *requestBody) railsRejects(contentType string) bool {
	if len(b.raw) == 0 || !b.unencodable() || !isJSONContentType(contentType) {
		return false
	}
	_, err := b.parseRuby()
	return err == nil
}

// normalizeJSON mirrors Ruby's parser limit, a non-empty array or object nested deeper
// than max_nesting is an error, and with munge Rails' deep munge, which drops nils from
// arrays.
func normalizeJSON(value any, depth int, munge bool) (any, error) {
	switch v := value.(type) {
	case map[string]any:
		if len(v) > 0 && depth > maxNesting {
			return nil, errors.New("JSON body nested too deeply")
		}
		for key, item := range v {
			switch item.(type) {
			case map[string]any, []any:
				normalized, err := normalizeJSON(item, depth+1, munge)
				if err != nil {
					return nil, err
				}
				v[key] = normalized
			}
		}
		return v, nil
	case []any:
		if len(v) > 0 && depth > maxNesting {
			return nil, errors.New("JSON body nested too deeply")
		}
		if munge {
			v = slices.DeleteFunc(v, func(item any) bool { return item == nil })
		}
		for i, item := range v {
			switch item.(type) {
			case map[string]any, []any:
				normalized, err := normalizeJSON(item, depth+1, munge)
				if err != nil {
					return nil, err
				}
				v[i] = normalized
			}
		}
		return v, nil
	default:
		return v, nil
	}
}

// unpairedSurrogates reports \u escapes of surrogates outside a high-low pair, which Go
// would decode to U+FFFD. Ruby rejects a lone high one and keeps a lone low one as
// invalid UTF-8. Backslashes only occur inside strings, so quotes needn't be tracked.
func unpairedSurrogates(body []byte) (high, low bool) {
	for i := 0; i < len(body); i++ {
		if body[i] != '\\' {
			continue
		}
		code, ok := hexEscape(body, i)
		if !ok {
			i++ // skip the escaped character, which may itself be a backslash
			continue
		}
		switch {
		case code >= 0xD800 && code <= 0xDBFF:
			if next, _ := hexEscape(body, i+6); next >= 0xDC00 && next <= 0xDFFF {
				i += 6
			} else {
				high = true
			}
		case code >= 0xDC00 && code <= 0xDFFF:
			low = true
		}
		i += 5
	}
	return high, low
}

// hexEscape reads the \uXXXX escape starting at body[i].
func hexEscape(body []byte, i int) (rune, bool) {
	if i+6 > len(body) || body[i] != '\\' || body[i+1] != 'u' {
		return 0, false
	}
	code, err := strconv.ParseUint(string(body[i+2:i+6]), 16, 16)
	return rune(code), err == nil
}
