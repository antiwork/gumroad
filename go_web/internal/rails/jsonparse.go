package rails

import (
	"bytes"
	"encoding/json"
	"errors"
	"unicode/utf8"
)

// json 2.13's default max_nesting for JSON.parse.
const jsonMaxNesting = 100

var errJSON = errors.New("invalid JSON")

var jsonLiterals = []struct {
	text  []byte
	value any
}{{[]byte("true"), true}, {[]byte("false"), false}, {[]byte("null"), nil}}

// parseRubyJSON is JSON.parse (json 2.13.2) as ActiveSupport::JSON.decode calls it, for the
// parameter parser. Objects become *Hash in Ruby's key order and numbers stay json.Number
// literals. Like Ruby it takes /* */ and // comments, drops the backslash of an unknown
// escape, refuses control characters in strings, raises on nesting past 100 non-empty
// containers and on an unpaired high surrogate, and keeps an unpaired low surrogate as the
// invalid UTF-8 bytes Ruby makes of it.
func parseRubyJSON(data []byte) (any, error) {
	p := &jsonParser{data: data}
	if err := p.skipSpace(); err != nil {
		return nil, err
	}
	value, err := p.value()
	if err != nil {
		return nil, err
	}
	if err := p.skipSpace(); err != nil {
		return nil, err
	}
	if p.pos != len(p.data) {
		return nil, errJSON
	}
	return value, nil
}

// ParseJSON is JSON.parse for values Rails itself serialized, such as the session.
func ParseJSON(data []byte) (any, error) { return parseRubyJSON(data) }

type jsonParser struct {
	data    []byte
	pos     int
	nesting int
}

// skipSpace is json_eat_whitespace: space, tab, CR, LF and comments.
func (p *jsonParser) skipSpace() error {
	for p.pos < len(p.data) {
		switch p.data[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		case '/':
			if p.pos+1 >= len(p.data) {
				return errJSON
			}
			switch p.data[p.pos+1] {
			case '*':
				end := bytes.Index(p.data[p.pos+2:], []byte("*/"))
				if end < 0 {
					return errJSON
				}
				p.pos += 2 + end + 2
			case '/':
				p.pos += 2
				for p.pos < len(p.data) && p.data[p.pos] != '\n' {
					p.pos++
				}
			default:
				return errJSON
			}
		default:
			return nil
		}
	}
	return nil
}

func (p *jsonParser) value() (any, error) {
	if p.pos >= len(p.data) {
		return nil, errJSON
	}
	switch c := p.data[p.pos]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		return p.string()
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	}
	for _, l := range jsonLiterals {
		if bytes.HasPrefix(p.data[p.pos:], l.text) {
			p.pos += len(l.text)
			return l.value, nil
		}
	}
	return nil, errJSON
}

// enter is the nesting check, which json runs only for a container that isn't empty.
func (p *jsonParser) enter() error {
	if p.nesting++; p.nesting > jsonMaxNesting {
		return ErrParse
	}
	return nil
}

func (p *jsonParser) array() (any, error) {
	p.pos++
	if err := p.skipSpace(); err != nil {
		return nil, err
	}
	list := []any{}
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return list, nil
	}
	if err := p.enter(); err != nil {
		return nil, err
	}
	for {
		item, err := p.value()
		if err != nil {
			return nil, err
		}
		list = append(list, item)
		if err := p.skipSpace(); err != nil {
			return nil, err
		}
		if p.pos >= len(p.data) {
			return nil, errJSON
		}
		switch p.data[p.pos] {
		case ']':
			p.pos++
			p.nesting--
			return list, nil
		case ',':
			p.pos++
			if err := p.skipSpace(); err != nil {
				return nil, err
			}
		default:
			return nil, errJSON
		}
	}
}

func (p *jsonParser) object() (any, error) {
	p.pos++
	if err := p.skipSpace(); err != nil {
		return nil, err
	}
	hash := NewHash()
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return hash, nil
	}
	if err := p.enter(); err != nil {
		return nil, err
	}
	for {
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return nil, errJSON
		}
		key, err := p.string()
		if err != nil {
			return nil, err
		}
		if err := p.skipSpace(); err != nil {
			return nil, err
		}
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return nil, errJSON
		}
		p.pos++
		if err := p.skipSpace(); err != nil {
			return nil, err
		}
		item, err := p.value()
		if err != nil {
			return nil, err
		}
		hash.Set(key.(string), item)
		if err := p.skipSpace(); err != nil {
			return nil, err
		}
		if p.pos >= len(p.data) {
			return nil, errJSON
		}
		switch p.data[p.pos] {
		case '}':
			p.pos++
			p.nesting--
			return hash, nil
		case ',':
			p.pos++
			if err := p.skipSpace(); err != nil {
				return nil, err
			}
		default:
			return nil, errJSON
		}
	}
}

// number is -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?, kept as its literal.
func (p *jsonParser) number() (any, error) {
	start := p.pos
	if p.data[p.pos] == '-' {
		p.pos++
	}
	digits := func() int {
		n := 0
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos++
			n++
		}
		return n
	}
	intStart := p.pos
	if n := digits(); n == 0 || (n > 1 && p.data[intStart] == '0') {
		return nil, errJSON
	}
	if p.pos < len(p.data) && p.data[p.pos] == '.' {
		p.pos++
		if digits() == 0 {
			return nil, errJSON
		}
	}
	if p.pos < len(p.data) && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E') {
		p.pos++
		if p.pos < len(p.data) && (p.data[p.pos] == '+' || p.data[p.pos] == '-') {
			p.pos++
		}
		if digits() == 0 {
			return nil, errJSON
		}
	}
	return json.Number(p.data[start:p.pos]), nil
}

// string is json_parse_string and json_string_unescape.
func (p *jsonParser) string() (any, error) {
	p.pos++
	start := p.pos
	for p.pos < len(p.data) && p.data[p.pos] != '"' {
		switch c := p.data[p.pos]; {
		case c == '\\':
			p.pos += 2
		case c < 0x20:
			return nil, errJSON
		default:
			p.pos++
		}
	}
	if p.pos >= len(p.data) {
		return nil, errJSON
	}
	raw := p.data[start:p.pos]
	p.pos++
	if bytes.IndexByte(raw, '\\') < 0 {
		return string(raw), nil
	}
	return unescapeJSON(raw)
}

func unescapeJSON(raw []byte) (string, error) {
	out := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c != '\\' {
			out = append(out, c)
			continue
		}
		i++
		switch raw[i] {
		case 'n':
			out = append(out, '\n')
		case 'r':
			out = append(out, '\r')
		case 't':
			out = append(out, '\t')
		case '"':
			out = append(out, '"')
		case '\\':
			out = append(out, '\\')
		case 'b':
			out = append(out, '\b')
		case 'f':
			out = append(out, '\f')
		case 'u':
			ch, ok := hex4(raw, i+1)
			if !ok {
				return "", errJSON
			}
			i += 4
			if ch&0xFC00 == 0xD800 {
				// json pairs a high surrogate with whatever \u escape follows, and turns one
				// followed by anything else into "?", dropping that next character.
				if i+1 > len(raw)-6 {
					return "", errJSON
				}
				if raw[i+1] == '\\' && raw[i+2] == 'u' {
					sur, ok := hex4(raw, i+3)
					if !ok {
						return "", errJSON
					}
					ch = ((ch & 0x3F) << 10) | ((((ch >> 6) & 0xF) + 1) << 16) | (sur & 0x3FF)
					i += 6
				} else {
					out = append(out, '?')
					i++
					continue
				}
			}
			out = appendUTF32(out, ch)
		default:
			// An unknown escape keeps its character and loses the backslash.
			out = append(out, raw[i])
		}
	}
	return string(out), nil
}

func hex4(raw []byte, at int) (rune, bool) {
	if at+4 > len(raw) {
		return 0, false
	}
	var n rune
	for _, c := range raw[at : at+4] {
		n <<= 4
		switch {
		case c >= '0' && c <= '9':
			n |= rune(c - '0')
		case c >= 'a' && c <= 'f':
			n |= rune(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			n |= rune(c - 'A' + 10)
		default:
			return 0, false
		}
	}
	return n, true
}

// appendUTF32 is convert_UTF32_to_UTF8, which encodes a lone surrogate as its three bytes.
func appendUTF32(out []byte, ch rune) []byte {
	if ch >= 0xD800 && ch <= 0xDFFF {
		return append(out, byte(0xE0|ch>>12), byte(0x80|(ch>>6)&0x3F), byte(0x80|ch&0x3F))
	}
	return utf8.AppendRune(out, ch)
}

// invalidParamEncoding is Request::Utils.check_param_encoding: any String value, at any
// depth, that isn't UTF-8 is an InvalidParameterError. Keys are not checked.
func invalidParamEncoding(v any) bool {
	switch v := v.(type) {
	case string:
		return !utf8.ValidString(v)
	case []any:
		for _, item := range v {
			if invalidParamEncoding(item) {
				return true
			}
		}
	case *Hash:
		for _, k := range v.keys {
			if invalidParamEncoding(v.values[k]) {
				return true
			}
		}
	}
	return false
}
