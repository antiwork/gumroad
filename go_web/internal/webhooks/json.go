package webhooks

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// Ruby's JSON.parse max_nesting.
const maxNesting = 100

var (
	errUnpairedHigh = errors.New("unpaired high surrogate escape in the JSON body")
	errTooDeep      = errors.New("JSON nested too deeply")
)

// parseJSON is JSON.parse (json 2.13.2): objects become sidekiq.Hash in Ruby's key order.
// loneLow is an unpaired low surrogate, kept by Ruby as a string that isn't UTF-8. Ruby
// also accepts comments and unknown escapes, which Go rejects and no sender sends.
func parseJSON(body []byte) (value any, loneLow bool, err error) {
	high, low := unpairedSurrogates(body)
	if high {
		return nil, false, errUnpairedHigh
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if value, err = decodeValue(decoder, 1); err != nil {
		return nil, false, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, false, errors.New("unexpected data after the JSON body")
	}
	return value, low, nil
}

func decodeValue(d *json.Decoder, depth int) (any, error) {
	token, err := d.Token()
	if err != nil {
		return nil, err
	}
	delim, isDelim := token.(json.Delim)
	if !isDelim {
		return token, nil
	}
	if delim == '[' {
		list := []any{}
		for d.More() {
			if depth > maxNesting {
				return nil, errTooDeep
			}
			item, err := decodeValue(d, depth+1)
			if err != nil {
				return nil, err
			}
			list = append(list, item)
		}
		_, err := d.Token()
		return list, err
	}
	hash := sidekiq.Hash{}
	var index map[string]int
	for d.More() {
		if depth > maxNesting {
			return nil, errTooDeep
		}
		key, err := d.Token()
		if err != nil {
			return nil, err
		}
		item, err := decodeValue(d, depth+1)
		if err != nil {
			return nil, err
		}
		hash, index = setPair(hash, index, key.(string), item)
	}
	_, err = d.Token()
	return hash, err
}

// setPair is Hash#[]=, indexing the keys once the hash outgrows a linear scan.
func setPair(h sidekiq.Hash, index map[string]int, key string, value any) (sidekiq.Hash, map[string]int) {
	if index != nil {
		if i, ok := index[key]; ok {
			h[i].Value = value
			return h, index
		}
	} else if i := pairIndex(h, key); i >= 0 {
		h[i].Value = value
		return h, index
	}
	h = append(h, sidekiq.Pair{Key: key, Value: value})
	switch {
	case index != nil:
		index[key] = len(h) - 1
	case len(h) > 16:
		index = make(map[string]int, len(h))
		for i, pair := range h {
			index[pair.Key] = i
		}
	}
	return h, index
}

func pairIndex(h sidekiq.Hash, key string) int {
	for i, pair := range h {
		if pair.Key == key {
			return i
		}
	}
	return -1
}

// get is h[key]; ok is false when the key is absent.
func get(h sidekiq.Hash, key string) (any, bool) {
	if i := pairIndex(h, key); i >= 0 {
		return h[i].Value, true
	}
	return nil, false
}

// unpairedSurrogates reports \u escapes of surrogates outside a high-low pair, which Go
// would decode to U+FFFD. Ruby rejects a lone high one and keeps a lone low one as
// invalid UTF-8. Backslashes only occur inside strings, so quotes needn't be tracked.
func unpairedSurrogates(body []byte) (high, low bool) {
	for i := bytes.IndexByte(body, '\\'); i >= 0 && i < len(body); i++ {
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

// fromParams converts a params hash to the job argument `params.to_unsafe_hash.to_hash` is.
func fromParams(v any) any {
	switch v := v.(type) {
	case *rails.Hash:
		out := make(sidekiq.Hash, 0, v.Len())
		for _, key := range v.Keys() {
			out = append(out, sidekiq.Pair{Key: key, Value: fromParams(v.Value(key))})
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = fromParams(item)
		}
		return out
	}
	return v
}

// rubyInfinity reports a JSON number Ruby parses to a Float that overflows; integers
// become Bignums instead.
func rubyInfinity(n json.Number) bool {
	if !strings.ContainsAny(string(n), ".eE") {
		return false
	}
	f, _ := n.Float64()
	return math.IsInf(f, 0)
}
