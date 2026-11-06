package sidekiq

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Hash is a Ruby Hash: its keys serialize in insertion order.
type Hash []Pair

type Pair struct {
	Key   string
	Value any
}

// ErrUnserializable wraps every Marshal failure: a job Sidekiq's strict args or
// JSON.generate would raise on, as opposed to a Redis failure on push.
var ErrUnserializable = errors.New("sidekiq: job is not serializable")

// JSON.generate's max_nesting, counted from the outermost container.
const maxNesting = 100

// Marshal is JSON.generate (json 2.13, the generator Sidekiq.dump_json calls): it leaves
// "/", "<", ">", "&" and U+2028/U+2029 alone, and writes floats as its fpconv does.
// json.Number values are written as Ruby would after parsing them back from a request.
func Marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := encode(&b, v, 0); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnserializable, err)
	}
	return b.Bytes(), nil
}

func encode(b *bytes.Buffer, v any, depth int) error {
	switch v := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(v))
	case string:
		return encodeString(b, v)
	case int:
		b.WriteString(strconv.Itoa(v))
	case int64:
		b.WriteString(strconv.FormatInt(v, 10))
	case float64:
		s, err := JSONFloat(v)
		if err != nil {
			return err
		}
		b.WriteString(s)
	case json.Number:
		s, err := rubyNumber(v)
		if err != nil {
			return err
		}
		b.WriteString(s)
	case []any:
		if depth++; depth > maxNesting {
			return fmt.Errorf("nesting of %d is too deep", depth)
		}
		b.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := encode(b, item, depth); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case Hash:
		if depth++; depth > maxNesting {
			return fmt.Errorf("nesting of %d is too deep", depth)
		}
		b.WriteByte('{')
		for i, pair := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := encodeString(b, pair.Key); err != nil {
				return err
			}
			b.WriteByte(':')
			if err := encode(b, pair.Value, depth); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return fmt.Errorf("%T is not a native JSON type", v)
	}
	return nil
}

func encodeString(b *bytes.Buffer, s string) error {
	if !utf8.ValidString(s) {
		return fmt.Errorf("source sequence is illegal/malformed utf-8")
	}
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c == '\b':
			b.WriteString(`\b`)
		case c == '\f':
			b.WriteString(`\f`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20:
			fmt.Fprintf(b, `\u%04x`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return nil
}

// RubyFloat is Float#to_s: the shortest round-tripping digits, in fixed notation while the
// decimal exponent is in (-4, 16], with ".0" on integral values.
func RubyFloat(f float64) (string, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "", fmt.Errorf("%v not allowed in JSON", f)
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0", nil
		}
		return "0.0", nil
	}
	sign := ""
	if f < 0 {
		sign, f = "-", -f
	}
	digits, exp := shortestDigits(f)
	decpt := exp + 1
	switch {
	case decpt > 0 && decpt <= 16:
		if len(digits) <= decpt {
			return sign + digits + strings.Repeat("0", decpt-len(digits)) + ".0", nil
		}
		return sign + digits[:decpt] + "." + digits[decpt:], nil
	case decpt <= 0 && decpt > -4:
		return sign + "0." + strings.Repeat("0", -decpt) + digits, nil
	}
	frac := digits[1:]
	if frac == "" {
		frac = "0"
	}
	return fmt.Sprintf("%s%s.%se%+03d", sign, digits[:1], frac, decpt-1), nil
}

// rubyNumber writes a JSON number as JSON.parse then JSON.generate would: integers keep
// their digits, anything with a fraction or exponent becomes a Float.
func rubyNumber(n json.Number) (string, error) {
	s := string(n)
	if !strings.ContainsAny(s, ".eE") {
		if strings.TrimLeft(s, "-0") == "" {
			return "0", nil
		}
		return s, nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return "", fmt.Errorf("%q is not a number Ruby can generate", s)
	}
	return JSONFloat(f)
}

// JSONFloat is the json gem's fpconv_dtoa and emit_digits.
func JSONFloat(f float64) (string, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "", fmt.Errorf("%v not allowed in JSON", f)
	}
	sign := ""
	if math.Signbit(f) {
		sign, f = "-", -f
	}
	if f == 0 {
		return sign + "0.0", nil
	}
	var buf [18]byte
	raw, k := grisu2(f, buf[:0])
	digits := string(raw)
	ndigits := len(digits)
	exp10 := k + ndigits - 1
	exp := exp10
	if exp < 0 {
		exp = -exp
	}
	maxTrailingZeros := 7
	if sign != "" {
		maxTrailingZeros--
	}
	if k >= 0 && exp < ndigits+maxTrailingZeros {
		return sign + digits + strings.Repeat("0", k) + ".0", nil
	}
	if k < 0 && (k > -7 || exp < 10) {
		offset := ndigits + k
		if offset <= 0 {
			return sign + "0." + strings.Repeat("0", -offset) + digits, nil
		}
		return sign + digits[:offset] + "." + digits[offset:], nil
	}
	if limit := 18 - len(sign); ndigits > limit {
		digits = digits[:limit]
	}
	out := sign + digits[:1]
	if len(digits) > 1 {
		out += "." + digits[1:]
	}
	expSign := "+"
	if exp10 < 0 {
		expSign = "-"
	}
	return out + "e" + expSign + strconv.Itoa(exp), nil
}

// shortestDigits returns f's shortest round-tripping digits and the decimal exponent of
// the first one.
func shortestDigits(f float64) (string, int) {
	mantissa, exponent, _ := strings.Cut(strconv.FormatFloat(f, 'e', -1, 64), "e")
	exp, _ := strconv.Atoi(exponent)
	return strings.Replace(mantissa, ".", "", 1), exp
}
