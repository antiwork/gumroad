package rails

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// RHash is a Ruby Hash as ActiveSupport encodes it: insertion-ordered, assignment to an
// existing key keeps its place, and symbol and string keys stay distinct even though both
// print the same.
type RHash struct {
	keys []rkey
	vals map[rkey]any
}

type rkey struct {
	name string
	str  bool // a String key; the zero value is a Symbol
}

func NewRHash() *RHash { return &RHash{vals: map[rkey]any{}} }

func (h *RHash) put(k rkey, v any) *RHash {
	if _, ok := h.vals[k]; !ok {
		h.keys = append(h.keys, k)
	}
	h.vals[k] = v
	return h
}

// Sym is h[:name] = v.
func (h *RHash) Sym(name string, v any) *RHash { return h.put(rkey{name: name}, v) }

// Str is h["name"] = v.
func (h *RHash) Str(name string, v any) *RHash { return h.put(rkey{name: name, str: true}, v) }

// Has and Get read a Symbol key.
func (h *RHash) Has(name string) bool {
	_, ok := h.vals[rkey{name: name}]
	return ok
}

func (h *RHash) Get(name string) any { return h.vals[rkey{name: name}] }

// Merge is Hash#merge! of other into h.
func (h *RHash) Merge(other *RHash) *RHash {
	for _, k := range other.keys {
		h.put(k, other.vals[k])
	}
	return h
}

// EncodeJSON is ActiveSupport::JSON.encode with this app's escaping of <, >, & and U+2028/9,
// and times in UTC at second precision. Values are nil, bool, int, int64, float64,
// json.Number, string, time.Time, []string, []any, *RHash and *Hash.
func EncodeJSON(v any) string {
	var b strings.Builder
	writeJSON(&b, v)
	return b.String()
}

func writeJSON(b *strings.Builder, v any) {
	switch v := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(v))
	case int:
		b.WriteString(strconv.Itoa(v))
	case int64:
		b.WriteString(strconv.FormatInt(v, 10))
	case float64:
		// Float#as_json is nil unless finite.
		if math.IsNaN(v) || math.IsInf(v, 0) {
			b.WriteString("null")
			return
		}
		s, _ := sidekiq.JSONFloat(v)
		b.WriteString(s)
	case json.Number:
		writeJSON(b, numberValue(v))
	case string:
		writeJSONString(b, v)
	case time.Time:
		// ActiveSupport::JSON::Encoding.time_precision = 0, and Rails reads datetimes as UTC.
		writeJSONString(b, v.UTC().Format("2006-01-02T15:04:05Z"))
	case []string:
		b.WriteByte('[')
		for i, s := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(b, s)
		}
		b.WriteByte(']')
	case []any:
		b.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSON(b, item)
		}
		b.WriteByte(']')
	case *RHash:
		b.WriteByte('{')
		for i, k := range v.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(b, k.name)
			b.WriteByte(':')
			writeJSON(b, v.vals[k])
		}
		b.WriteByte('}')
	case *Hash:
		b.WriteByte('{')
		for i, k := range v.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(b, k)
			b.WriteByte(':')
			writeJSON(b, v.values[k])
		}
		b.WriteByte('}')
	default:
		panic(fmt.Sprintf("rails: cannot encode %T", v))
	}
}

// numberValue is the Integer or Float Ruby's JSON parser makes of a number.
func numberValue(n json.Number) any {
	if !strings.ContainsAny(string(n), ".eE") {
		if i, err := n.Int64(); err == nil {
			return i
		}
	}
	f, _ := strconv.ParseFloat(string(n), 64)
	return f
}

const hexDigits = "0123456789abcdef"

// writeJSONString is JSON.generate's escaping followed by ActiveSupport's.
func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == '<' || r == '>' || r == '&':
			b.WriteString(`\u00`)
			b.WriteByte(hexDigits[r>>4])
			b.WriteByte(hexDigits[r&0xf])
		case r == '\u2028':
			b.WriteString(`\u2028`)
		case r == '\u2029':
			b.WriteString(`\u2029`)
		case r == utf8.RuneError && size == 1:
			// Rails raises on invalid UTF-8; the sanitizer and utf8mb4 columns leave none.
			b.WriteString("\uFFFD")
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
}
