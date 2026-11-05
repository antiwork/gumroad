package rails

import (
	"encoding/base64"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"unicode"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// Param values are what ActionController::Parameters hands an action: string, nil,
// json.Number, bool, []any, *Hash, and File for an upload. A string can hold invalid UTF-8
// only as a JSON object key, as Ruby allows.

// Hash is a params hash; keys keep Ruby's insertion order.
type Hash struct {
	keys   []string
	values map[string]any
}

// File stands in for an ActionDispatch::Http::UploadedFile, which no ported action reads.
type File struct{}

func NewHash() *Hash { return &Hash{values: map[string]any{}} }

func (h *Hash) Get(key string) (any, bool) {
	v, ok := h.values[key]
	return v, ok
}

// Value is h[key], nil when absent.
func (h *Hash) Value(key string) any { return h.values[key] }

func (h *Hash) Set(key string, value any) {
	if _, ok := h.values[key]; !ok {
		h.keys = append(h.keys, key)
	}
	h.values[key] = value
}

// Delete is Hash#delete.
func (h *Hash) Delete(key string) {
	if _, ok := h.values[key]; !ok {
		return
	}
	delete(h.values, key)
	for i, k := range h.keys {
		if k == key {
			h.keys = append(h.keys[:i:i], h.keys[i+1:]...)
			break
		}
	}
}

func (h *Hash) Keys() []string { return h.keys }

func (h *Hash) Len() int { return len(h.keys) }

// Blank is Object#blank?; strings use [[:space:]], which is Unicode White_Space.
func Blank(v any) bool {
	switch v := v.(type) {
	case nil:
		return true
	case string:
		return strings.TrimFunc(v, unicode.IsSpace) == ""
	case bool:
		return !v
	case []any:
		return len(v) == 0
	case *Hash:
		return v.Len() == 0
	}
	return false
}

func Present(v any) bool { return !Blank(v) }

// Truthy is Ruby truthiness: everything but nil and false.
func Truthy(v any) bool {
	b, isBool := v.(bool)
	return v != nil && (!isBool || b)
}

// String is #to_s for the scalars a param or column holds; ok is false for an array, hash
// or file, which the ported actions treat as invalid wherever Rails expects a String.
func String(v any) (string, bool) {
	switch v := v.(type) {
	case nil:
		return "", true
	case string:
		return v, true
	case bool:
		return strconv.FormatBool(v), true
	case json.Number:
		return numberToS(v), true
	case int:
		return strconv.Itoa(v), true
	case int64:
		return strconv.FormatInt(v, 10), true
	case float64:
		s, err := sidekiq.RubyFloat(v)
		return s, err == nil
	}
	return "", false
}

// ToS is String with "" for what isn't a scalar.
func ToS(v any) string {
	s, _ := String(v)
	return s
}

// ColumnString is what ActiveModel::Type::String stores: true and false become "t" and
// "f", nil stays NULL, other scalars are #to_s. ok is false for a non-scalar.
func ColumnString(v any) (*string, bool) {
	switch v := v.(type) {
	case nil:
		return nil, true
	case bool:
		s := "f"
		if v {
			s = "t"
		}
		return &s, true
	}
	s, ok := String(v)
	return &s, ok
}

// BooleanCast is ActiveModel::Type::Boolean#cast; nil is Ruby's nil.
func BooleanCast(v any) *bool {
	f, t := false, true
	switch v := v.(type) {
	case nil:
		return nil
	case bool:
		return &v
	case string:
		switch v {
		case "":
			return nil
		case "0", "f", "F", "false", "FALSE", "off", "OFF":
			return &f
		}
	case json.Number:
		// FALSE_VALUES.include? compares with ==, so 0.0 is false too.
		if n, err := strconv.ParseFloat(string(v), 64); err == nil && n == 0 {
			return &f
		}
	}
	return &t
}

// LastPresent is Array.wrap(value).compact_blank.last.
func LastPresent(v any) any {
	list, isList := v.([]any)
	if !isList {
		list = []any{v}
	}
	for i := len(list) - 1; i >= 0; i-- {
		if Present(list[i]) {
			return list[i]
		}
	}
	return nil
}

// Join is how Array#join(sep) renders a param: nested arrays flatten with the separator.
// ok is false when it meets a hash or file.
func Join(v any, sep string) (string, bool) {
	list, isList := v.([]any)
	if !isList {
		return String(v)
	}
	parts := make([]string, len(list))
	for i, item := range list {
		part, ok := Join(item, sep)
		if !ok {
			return "", false
		}
		parts[i] = part
	}
	return strings.Join(parts, sep), true
}

// numberToS is Integer#to_s or Float#to_s for a JSON number Rails parsed. An integer
// literal is already canonical except for -0, so no big-number arithmetic is needed.
func numberToS(n json.Number) string {
	s := string(n)
	if !strings.ContainsAny(s, ".eE") {
		if s == "-0" {
			return "0"
		}
		return s
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		if strings.HasPrefix(s, "-") {
			return "-Infinity"
		}
		return "Infinity"
	}
	out, _ := sidekiq.RubyFloat(f)
	return out
}

// StringToI is String#to_i. ok is false where Ruby's result is a Bignum outside int64;
// scanning stops there, so a long run of digits costs no more than twenty.
func StringToI(s string) (n int64, ok bool) {
	i := 0
	for i < len(s) && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')) {
		i++
	}
	negative := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		negative = s[i] == '-'
		i++
	}
	var u uint64
	seen := false
	for ; i < len(s); i++ {
		c := s[i]
		if c == '_' && seen && i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' && s[i-1] != '_' {
			continue
		}
		if c < '0' || c > '9' {
			break
		}
		seen = true
		if u > (math.MaxUint64-9)/10 {
			return 0, false
		}
		u = u*10 + uint64(c-'0')
	}
	switch {
	case negative && u <= 1<<63:
		return -int64(u), true
	case !negative && u <= math.MaxInt64:
		return int64(u), true
	}
	return 0, false
}

var urlsafeReplacer = strings.NewReplacer("-", "+", "_", "/")

// URLSafeDecode64 is Base64.urlsafe_decode64: it pads unpadded input, maps -_ to +/ and
// decodes strictly, so standard-alphabet input decodes too.
func URLSafeDecode64(s string) ([]byte, bool) {
	if strings.ContainsAny(s, "\r\n") {
		return nil, false
	}
	if !strings.HasSuffix(s, "=") && len(s)%4 != 0 {
		s += strings.Repeat("=", 4-len(s)%4)
	}
	b, err := base64.StdEncoding.Strict().DecodeString(urlsafeReplacer.Replace(s))
	return b, err == nil
}
