package rails

import (
	"bytes"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"regexp"
	"strings"
	"unicode/utf8"
)

const (
	// ActionDispatch::ParamBuilder.default's depth, for the query string.
	railsParamDepthLimit = 100
	// Rack::Request#POST runs first on bodies, with Rack::QueryParser's limits; its
	// QueryLimitError (alias ParamsTooDeepError) is a BadRequest too.
	rackParamDepthLimit    = 32
	rackQueryBytesizeLimit = 4194304
	rackQueryParamsLimit   = 4096
)

var (
	rackMediaTypeSplit = regexp.MustCompile(`\s*[;,]\s*`)
	contentTypeHead    = regexp.MustCompile(`^([^,;]*)`)
	multipartPattern   = regexp.MustCompile(`(?i)\Amultipart/.*boundary="?([^";,]+)"?`)
)

// rackMediaType is Rack::Request#media_type; "" stands for nil.
func rackMediaType(contentType string) string {
	if contentType == "" {
		return ""
	}
	return strings.ToLower(rackMediaTypeSplit.Split(contentType, 2)[0])
}

// contentMimeType is Request#content_mime_type's symbol: "" when the header is absent or
// unregistered. An invalid type raises Mime::Type::InvalidMimeType, a 406.
func contentMimeType(contentType string, present bool) (string, error) {
	if !present {
		return "", nil
	}
	head := strings.ToLower(strings.TrimSpace(contentTypeHead.FindStringSubmatch(contentType)[1]))
	return lookupMime(head)
}

// queryPairs is ActionDispatch::QueryParser.each_pair with the default "&" separator.
func queryPairs(s string) ([][2]*string, error) {
	var pairs [][2]*string
	for _, part := range splitAmpersands(s) {
		if part == "" {
			continue
		}
		k, v, hasValue := strings.Cut(part, "=")
		key, ok := DecodeWWWFormComponent(k)
		if !ok {
			return nil, ErrBadRequest
		}
		var value *string
		if hasValue {
			decoded, ok := DecodeWWWFormComponent(v)
			if !ok {
				return nil, ErrBadRequest
			}
			value = &decoded
		}
		pairs = append(pairs, [2]*string{&key, value})
	}
	return pairs, nil
}

// splitAmpersands is split(/& */n), which drops trailing empty fields.
func splitAmpersands(s string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '&' {
			parts = append(parts, s[start:i])
			j := i + 1
			for j < len(s) && s[j] == ' ' {
				j++
			}
			start = j
			i = j - 1
		}
	}
	parts = append(parts, s[start:])
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// fromPairs is ActionDispatch::ParamBuilder#from_pairs.
func fromPairs(pairs [][2]*string, depthLimit int) (*Hash, error) {
	params := NewHash()
	for _, pair := range pairs {
		var v any
		if pair[1] != nil {
			v = *pair[1]
		}
		if _, err := storeNestedParam(params, *pair[0], v, 0, depthLimit); err != nil {
			return nil, err
		}
	}
	return params, nil
}

// storeNestedParam is ParamBuilder#store_nested_param, with perform_deep_munge on. It
// returns what Ruby's version returns: params, a one-element array, or nil.
func storeNestedParam(params *Hash, name string, v any, depth, depthLimit int) (any, error) {
	if depth >= depthLimit {
		return nil, ErrBadRequest
	}
	var k, after string
	switch {
	case depth == 0:
		if start := indexFrom(name, "[", 1); start >= 0 {
			k, after = name[:start], name[start:]
		} else {
			k = name
		}
	case strings.HasPrefix(name, "[]"):
		k, after = "[]", name[2:]
	case strings.HasPrefix(name, "["):
		if start := indexFrom(name, "]", 1); start >= 0 {
			k, after = name[1:start], name[start+1:]
		} else {
			k = name
		}
	default:
		k = name
	}
	// Ruby returns nil here, and the callers store that nil.
	if k == "" {
		return nil, nil
	}
	if !utf8.ValidString(k) {
		return nil, ErrBadRequest
	}
	if s, isString := v.(string); depth == 0 && isString && !utf8.ValidString(s) {
		return nil, ErrBadRequest
	}

	switch {
	case after == "":
		if k == "[]" && depth != 0 {
			if v != nil {
				return []any{v}, nil
			}
			return []any{}, nil
		}
		params.Set(k, v)
	case after == "[":
		params.Set(name, v)
	case after == "[]":
		list, err := listAt(params, k)
		if err != nil {
			return nil, err
		}
		if v != nil {
			list = append(list, v)
		}
		params.Set(k, list)
	case strings.HasPrefix(after, "[]"):
		childKey := after[2:]
		if len(after) > 3 && after[2] == '[' && strings.HasSuffix(after, "]") {
			if inner := after[3 : len(after)-1]; inner != "" && !strings.ContainsAny(inner, "[]") {
				childKey = inner
			}
		}
		list, err := listAt(params, k)
		if err != nil {
			return nil, err
		}
		if last, isHash := lastHash(list); isHash && !hashHasKey(last, childKey) {
			if _, err := storeNestedParam(last, childKey, v, depth+1, depthLimit); err != nil {
				return nil, err
			}
		} else {
			child, err := storeNestedParam(NewHash(), childKey, v, depth+1, depthLimit)
			if err != nil {
				return nil, err
			}
			list = append(list, child)
		}
		params.Set(k, list)
	default:
		existing, _ := params.Get(k)
		if existing == nil {
			existing = NewHash()
		}
		hash, isHash := existing.(*Hash)
		if !isHash {
			return nil, ErrBadRequest
		}
		stored, err := storeNestedParam(hash, after, v, depth+1, depthLimit)
		if err != nil {
			return nil, err
		}
		params.Set(k, stored)
	}
	return params, nil
}

func listAt(params *Hash, k string) ([]any, error) {
	existing, _ := params.Get(k)
	if existing == nil {
		return []any{}, nil
	}
	list, isList := existing.([]any)
	if !isList {
		return nil, ErrBadRequest
	}
	return list, nil
}

func indexFrom(s, sub string, from int) int {
	if from > len(s) {
		return -1
	}
	if i := strings.Index(s[from:], sub); i >= 0 {
		return i + from
	}
	return -1
}

func lastHash(list []any) (*Hash, bool) {
	if len(list) == 0 {
		return nil, false
	}
	h, ok := list[len(list)-1].(*Hash)
	return h, ok
}

// hashHasKey is params_hash_has_key?.
func hashHasKey(h *Hash, key string) bool {
	if strings.Contains(key, "[]") {
		return false
	}
	var current any = h
	for _, part := range strings.FieldsFunc(key, func(r rune) bool { return r == '[' || r == ']' }) {
		hash, ok := current.(*Hash)
		if !ok {
			return false
		}
		if current, ok = hash.Get(part); !ok {
			return false
		}
	}
	return true
}

// jsonParams is the JSON parameter parser: a Hash becomes the params, anything else is
// wrapped as _json. from_hash then refuses a String value that isn't UTF-8, a BadRequest,
// and deep munging drops nils from arrays.
func jsonParams(body []byte) (*Hash, error) {
	value, err := parseRubyJSON(body)
	if err != nil {
		return nil, ErrParse
	}
	params, isHash := value.(*Hash)
	if !isHash {
		params = NewHash()
		params.Set("_json", value)
	}
	if invalidParamEncoding(params) {
		return nil, ErrBadRequest
	}
	munge(params)
	return params, nil
}

func munge(v any) any {
	switch v := v.(type) {
	case []any:
		out := v[:0]
		for _, item := range v {
			if item != nil {
				out = append(out, munge(item))
			}
		}
		return out
	case *Hash:
		for _, k := range v.keys {
			v.values[k] = munge(v.values[k])
		}
	}
	return v
}

// bodyParams is Request#POST for a body the sanitizer has already rewritten.
func bodyParams(method, contentType, rackType string, hasContentType bool, body []byte) (*Hash, error) {
	symbol, err := contentMimeType(contentType, hasContentType)
	if err != nil {
		return nil, err
	}
	if symbol == "json" {
		if len(body) == 0 {
			return NewHash(), nil
		}
		return jsonParams(body)
	}

	form := (method == "POST" && rackType == "") || rackType == "application/x-www-form-urlencoded" || rackType == "multipart/form-data"
	if !form && rackType != "multipart/related" && rackType != "multipart/mixed" {
		return NewHash(), nil
	}
	if m := multipartPattern.FindStringSubmatch(contentType); m != nil {
		return multipartParams(body, m[1])
	}
	if !form {
		return NewHash(), nil
	}
	vars := strings.TrimSuffix(string(body), "\x00")
	if len(vars) > rackQueryBytesizeLimit || len(splitAmpersands(vars)) > rackQueryParamsLimit {
		return nil, ErrBadRequest
	}
	pairs, err := queryPairs(vars)
	if err != nil {
		return nil, err
	}
	return fromPairs(pairs, rackParamDepthLimit)
}

// multipartParams is Rack's multipart parser: text fields as strings, files as File.
func multipartParams(body []byte, boundary string) (*Hash, error) {
	params := NewHash()
	reader := multipart.NewReader(bytes.NewReader(body), boundary)
	for {
		part, err := reader.NextRawPart()
		if errors.Is(err, io.EOF) {
			return params, nil
		}
		if err != nil {
			return nil, ErrBadRequest
		}
		_, dispositionParams, _ := mime.ParseMediaType(part.Header.Get("Content-Disposition"))
		name := dispositionParams["name"]
		filename, hasFilename := dispositionParams["filename"]
		data, err := io.ReadAll(part)
		if err != nil {
			return nil, ErrBadRequest
		}
		if name == "" || (hasFilename && filename == "") {
			continue
		}
		var value any = string(data)
		if hasFilename {
			value = File{}
		}
		if _, err := storeNestedParam(params, name, value, 0, rackParamDepthLimit); err != nil {
			return nil, err
		}
	}
}

// mergeParams is request_parameters.merge(query_parameters): query keys win.
func mergeParams(body, query *Hash) *Hash {
	merged := NewHash()
	for _, k := range body.keys {
		merged.Set(k, body.values[k])
	}
	for _, k := range query.keys {
		merged.Set(k, query.values[k])
	}
	return merged
}
