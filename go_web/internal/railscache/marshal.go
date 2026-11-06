package railscache

import (
	"fmt"
	"math"
	"math/big"
	"reflect"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Ruby values, as Read returns them and Write takes them: nil, bool, int64 (*big.Int past
// int64), float64, string (a UTF-8 String), ASCII, Binary, Symbol, []any and Hash. Write
// also takes the other Go integer types, float32 and any slice.

// ASCII is a String in US-ASCII, as Integer#to_s returns.
type ASCII string

// Binary is a String in ASCII-8BIT.
type Binary string

type Symbol string

// Hash is a Ruby Hash: pairs in insertion order, keys of any type.
type Hash []Pair

type Pair struct {
	Key   any
	Value any
}

const maxDepth = 100

// A length is only bounded by the bytes left, at every nesting level, so containers grow
// past this instead of trusting it.
const maxPrealloc = 1024

// load is Marshal.load for the types above. Anything else is ErrUnported.
func load(data []byte) (any, error) {
	if len(data) < 2 || data[0] != 4 || data[1] != 8 {
		return nil, fmt.Errorf("%w: marshal version %x", ErrUnported, data[:min(len(data), 2)])
	}
	l := &loader{data: data, pos: 2}
	// Marshal.load ignores bytes after the first object.
	return l.object(0)
}

type loader struct {
	data []byte
	pos  int
	objs []any // r_entry's table, which '@' indexes
	syms []Symbol
}

// building marks a container in objs until it is filled; a link to it is a cycle.
type building struct{}

func (l *loader) unported(format string, args ...any) error {
	return fmt.Errorf("%w: marshal: %s at byte %d", ErrUnported, fmt.Sprintf(format, args...), l.pos)
}

func (l *loader) byte() (byte, error) {
	if l.pos >= len(l.data) {
		return 0, l.unported("data too short")
	}
	b := l.data[l.pos]
	l.pos++
	return b, nil
}

// long is r_long.
func (l *loader) long() (int64, error) {
	b, err := l.byte()
	if err != nil {
		return 0, err
	}
	c := int64(int8(b))
	switch {
	case c == 0:
		return 0, nil
	case c > 4:
		return c - 5, nil
	case c < -4:
		return c + 5, nil
	case c > 0:
		var x int64
		for i := range c {
			b, err := l.byte()
			if err != nil {
				return 0, err
			}
			x |= int64(b) << (8 * i)
		}
		return x, nil
	}
	x := int64(-1)
	for i := range -c {
		b, err := l.byte()
		if err != nil {
			return 0, err
		}
		x &^= 0xff << (8 * i)
		x |= int64(b) << (8 * i)
	}
	return x, nil
}

func (l *loader) bytes() ([]byte, error) {
	n, err := l.long()
	if err != nil {
		return nil, err
	}
	if n < 0 || n > int64(len(l.data)-l.pos) {
		return nil, l.unported("data too short")
	}
	b := l.data[l.pos : l.pos+int(n)]
	l.pos += int(n)
	return b, nil
}

func (l *loader) entry(v any) int {
	l.objs = append(l.objs, v)
	return len(l.objs) - 1
}

func (l *loader) object(depth int) (any, error) {
	if depth > maxDepth {
		return nil, l.unported("nesting too deep")
	}
	t, err := l.byte()
	if err != nil {
		return nil, err
	}
	switch t {
	case '0':
		return nil, nil
	case 'T':
		return true, nil
	case 'F':
		return false, nil
	case 'i':
		return l.long()
	case 'l':
		return l.bignum()
	case 'f':
		return l.float()
	case '"':
		b, err := l.bytes()
		if err != nil {
			return nil, err
		}
		v := Binary(b)
		l.entry(v)
		return v, nil
	case 'I':
		return l.ivar(depth)
	case ':':
		return l.symbol(false, depth)
	case ';':
		n, err := l.long()
		if err != nil {
			return nil, err
		}
		if n < 0 || n >= int64(len(l.syms)) {
			return nil, l.unported("bad symlink %d", n)
		}
		return l.syms[n], nil
	case '@':
		n, err := l.long()
		if err != nil {
			return nil, err
		}
		if n < 0 || n >= int64(len(l.objs)) {
			return nil, l.unported("bad link %d", n)
		}
		if _, ok := l.objs[n].(building); ok {
			return nil, l.unported("cyclic link %d", n)
		}
		return l.objs[n], nil
	case '[':
		n, err := l.long()
		if err != nil {
			return nil, err
		}
		if n < 0 || n > int64(len(l.data)-l.pos) {
			return nil, l.unported("data too short")
		}
		idx := l.entry(building{})
		a := make([]any, 0, min(n, maxPrealloc))
		for range n {
			v, err := l.object(depth + 1)
			if err != nil {
				return nil, err
			}
			a = append(a, v)
		}
		l.objs[idx] = a
		return a, nil
	case '{':
		n, err := l.long()
		if err != nil {
			return nil, err
		}
		if n < 0 || n > int64(len(l.data)-l.pos) {
			return nil, l.unported("data too short")
		}
		idx := l.entry(building{})
		h := make(Hash, 0, min(n, maxPrealloc))
		for range n {
			k, err := l.object(depth + 1)
			if err != nil {
				return nil, err
			}
			v, err := l.object(depth + 1)
			if err != nil {
				return nil, err
			}
			h = append(h, Pair{k, v})
		}
		l.objs[idx] = h
		return h, nil
	}
	// '}' (a default value), 'o', 'C', 'u', 'U', 'e', 'S', '/', 'c', 'm', 'd', ...
	return nil, l.unported("type %q", t)
}

// bignum keeps r_entry's numbering: Ruby registers the Integer even when it fits a Fixnum.
func (l *loader) bignum() (any, error) {
	sign, err := l.byte()
	if err != nil {
		return nil, err
	}
	shorts, err := l.long()
	if err != nil {
		return nil, err
	}
	if (sign != '+' && sign != '-') || shorts < 0 || shorts > int64(len(l.data)-l.pos)/2 {
		return nil, l.unported("bad bignum")
	}
	le := l.data[l.pos : l.pos+int(shorts)*2]
	l.pos += len(le)
	be := make([]byte, len(le))
	for i, b := range le {
		be[len(le)-1-i] = b
	}
	n := new(big.Int).SetBytes(be)
	if sign == '-' {
		n.Neg(n)
	}
	var v any = n
	if n.IsInt64() {
		v = n.Int64()
	}
	l.entry(v)
	return v, nil
}

func (l *loader) float() (any, error) {
	b, err := l.bytes()
	if err != nil {
		return nil, err
	}
	var f float64
	switch s := string(b); s {
	case "nan":
		f = math.NaN()
	case "inf":
		f = math.Inf(1)
	case "-inf":
		f = math.Inf(-1)
	default:
		// w_float only writes these characters; ParseFloat and Ruby's strtod differ on others
		// (hex, "Infinity", 1.8's NUL-separated mantissa bytes).
		if strings.Trim(s, "0123456789.eE+-") != "" {
			return nil, l.unported("float %q", s)
		}
		if f, err = strconv.ParseFloat(s, 64); err != nil {
			return nil, l.unported("float %q", s)
		}
	}
	l.entry(f)
	return f, nil
}

// ivar is an 'I'-wrapped String or Symbol whose one ivar is its encoding (sym2encidx).
// Any other ivar, or an encoding other than UTF-8 or US-ASCII, is unported.
func (l *loader) ivar(depth int) (any, error) {
	t, err := l.byte()
	if err != nil {
		return nil, err
	}
	switch t {
	case ':':
		return l.symbol(true, depth)
	case '"':
	default:
		return nil, l.unported("ivars on type %q", t)
	}
	b, err := l.bytes()
	if err != nil {
		return nil, err
	}
	idx := l.entry(Binary(b))
	isUTF8, err := l.encoding(depth)
	if err != nil {
		return nil, err
	}
	var v any = ASCII(b)
	if isUTF8 {
		v = string(b)
	}
	l.objs[idx] = v
	return v, nil
}

// encoding reads r_ivar's count and the single :E ivar; true is UTF-8, false US-ASCII.
func (l *loader) encoding(depth int) (bool, error) {
	n, err := l.long()
	if err != nil {
		return false, err
	}
	if n != 1 {
		return false, l.unported("%d ivars", n)
	}
	t, err := l.byte()
	if err != nil {
		return false, err
	}
	var name any
	switch t {
	case ':':
		name, err = l.symbol(false, depth+1)
	case ';':
		l.pos--
		name, err = l.object(depth + 1)
	default:
		return false, l.unported("ivar name type %q", t)
	}
	if err != nil {
		return false, err
	}
	if name != Symbol("E") {
		return false, l.unported("ivar %v", name)
	}
	v, err := l.object(depth + 1)
	if err != nil {
		return false, err
	}
	b, ok := v.(bool)
	if !ok {
		return false, l.unported("encoding %v", v)
	}
	return b, nil
}

// symbol is r_symreal: the symbol takes its index before its encoding ivar is read.
func (l *loader) symbol(ivar bool, depth int) (any, error) {
	b, err := l.bytes()
	if err != nil {
		return nil, err
	}
	s := Symbol(b)
	l.syms = append(l.syms, s)
	if ivar {
		isUTF8, err := l.encoding(depth)
		if err != nil {
			return nil, err
		}
		if !isASCII(string(b)) && (!isUTF8 || !utf8.Valid(b)) {
			return nil, l.unported("symbol encoding")
		}
	} else if !isASCII(string(b)) {
		return nil, l.unported("binary symbol")
	}
	return s, nil
}

// Dump is Marshal.dump for the types load returns. Like Ruby it links repeated symbols,
// repeated flonums, and repeated String keys of Hashes (Hash#[]= interns those, so equal
// keys are one object). Other Strings and Floats are taken to be distinct objects.
func Dump(v any) ([]byte, error) {
	d := &dumper{buf: []byte{4, 8}, syms: map[Symbol]int{}, keys: map[any]int{}, flonums: map[uint64]int{}}
	if err := d.object(v, false, 0); err != nil {
		return nil, err
	}
	return d.buf, nil
}

type dumper struct {
	buf     []byte
	objs    int // arg->data's size: the next object's link index
	syms    map[Symbol]int
	keys    map[any]int
	flonums map[uint64]int
}

// long is w_long.
func (d *dumper) long(x int64) {
	switch {
	case x == 0:
		d.buf = append(d.buf, 0)
		return
	case 0 < x && x < 123:
		d.buf = append(d.buf, byte(x+5))
		return
	case -124 < x && x < 0:
		d.buf = append(d.buf, byte(x-5))
		return
	}
	var b [8]byte
	for i := 1; i <= 8; i++ {
		b[i-1] = byte(x)
		x >>= 8
		if x == 0 {
			d.buf = append(d.buf, byte(i))
			d.buf = append(d.buf, b[:i]...)
			return
		}
		if x == -1 {
			d.buf = append(d.buf, byte(-i))
			d.buf = append(d.buf, b[:i]...)
			return
		}
	}
}

func (d *dumper) bytes(s string) {
	d.long(int64(len(s)))
	d.buf = append(d.buf, s...)
}

func (d *dumper) link(idx int) {
	d.buf = append(d.buf, '@')
	d.long(int64(idx))
}

func (d *dumper) remember() int {
	d.objs++
	return d.objs - 1
}

func (d *dumper) object(v any, hashKey bool, depth int) error {
	if depth > maxDepth {
		return fmt.Errorf("%w: marshal: nesting too deep", ErrUnported)
	}
	switch v := v.(type) {
	case nil:
		d.buf = append(d.buf, '0')
	case bool:
		if v {
			d.buf = append(d.buf, 'T')
		} else {
			d.buf = append(d.buf, 'F')
		}
	case int:
		d.integer(big.NewInt(int64(v)))
	case int8:
		d.integer(big.NewInt(int64(v)))
	case int16:
		d.integer(big.NewInt(int64(v)))
	case int32:
		d.integer(big.NewInt(int64(v)))
	case int64:
		d.integer(big.NewInt(v))
	case uint:
		d.integer(new(big.Int).SetUint64(uint64(v)))
	case uint8:
		d.integer(big.NewInt(int64(v)))
	case uint16:
		d.integer(big.NewInt(int64(v)))
	case uint32:
		d.integer(big.NewInt(int64(v)))
	case uint64:
		d.integer(new(big.Int).SetUint64(v))
	case *big.Int:
		if v == nil {
			return fmt.Errorf("%w: marshal: nil *big.Int", ErrUnported)
		}
		d.integer(v)
	case float32:
		d.float(float64(v))
	case float64:
		d.float(v)
	case string:
		d.str(v, encUTF8, hashKey)
	case ASCII:
		d.str(string(v), encASCII, hashKey)
	case Binary:
		d.str(string(v), encBinary, hashKey)
	case Symbol:
		return d.symbol(v)
	case Hash:
		d.buf = append(d.buf, '{')
		d.remember()
		d.long(int64(len(v)))
		for _, p := range v {
			if err := d.object(p.Key, true, depth+1); err != nil {
				return err
			}
			if err := d.object(p.Value, false, depth+1); err != nil {
				return err
			}
		}
	case []any:
		d.buf = append(d.buf, '[')
		d.remember()
		d.long(int64(len(v)))
		for _, e := range v {
			if err := d.object(e, false, depth+1); err != nil {
				return err
			}
		}
	case []byte:
		return fmt.Errorf("%w: marshal: []byte (use Binary)", ErrUnported)
	default:
		rv := reflect.ValueOf(v)
		if rv.Kind() != reflect.Slice {
			return fmt.Errorf("%w: marshal: %T", ErrUnported, v)
		}
		a := make([]any, rv.Len())
		for i := range a {
			a[i] = rv.Index(i).Interface()
		}
		return d.object(a, false, depth)
	}
	return nil
}

// integer writes a Fixnum as 'i' only when its tagged VALUE fits 32 bits; past that Ruby
// converts it to a Bignum, which takes an object index.
func (d *dumper) integer(n *big.Int) {
	if n.IsInt64() {
		if x := n.Int64(); x >= -1<<30 && x < 1<<30 {
			d.buf = append(d.buf, 'i')
			d.long(x)
			return
		}
	}
	d.remember()
	d.buf = append(d.buf, 'l')
	if n.Sign() < 0 {
		d.buf = append(d.buf, '-')
	} else {
		d.buf = append(d.buf, '+')
	}
	be := new(big.Int).Abs(n).Bytes()
	shorts := (len(be) + 1) / 2
	d.long(int64(shorts))
	for i := range shorts * 2 {
		var b byte
		if i < len(be) {
			b = be[len(be)-1-i]
		}
		d.buf = append(d.buf, b)
	}
}

// isFlonum is rb_float_new_inline's test: these Floats are immediates, so equal ones are
// the same object and Marshal links them.
func isFlonum(f float64) bool {
	bits := math.Float64bits(f)
	if bits == 0 {
		return true
	}
	b := (bits >> 60) & 7
	return bits != 0x3000000000000000 && (b == 3 || b == 4)
}

func (d *dumper) float(f float64) {
	if isFlonum(f) {
		bits := math.Float64bits(f)
		if idx, ok := d.flonums[bits]; ok {
			d.link(idx)
			return
		}
		d.flonums[bits] = d.remember()
	} else {
		d.remember()
	}
	d.buf = append(d.buf, 'f')
	d.bytes(marshalFloat(f))
}

// marshalFloat is w_float: ruby_dtoa's shortest digits, in exponent form when the decimal
// point falls outside [-3, digits].
func marshalFloat(f float64) string {
	switch {
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case math.IsNaN(f):
		return "nan"
	case f == 0:
		if math.Signbit(f) {
			return "-0"
		}
		return "0"
	}
	sign := ""
	if f < 0 {
		sign, f = "-", -f
	}
	mantissa, exponent, _ := strings.Cut(strconv.FormatFloat(f, 'e', -1, 64), "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	exp, _ := strconv.Atoi(exponent)
	decpt := exp + 1
	switch {
	case decpt < -3 || decpt > len(digits):
		out := sign + digits[:1]
		if len(digits) > 1 {
			out += "." + digits[1:]
		}
		return out + "e" + strconv.Itoa(decpt-1)
	case decpt > 0:
		if decpt == len(digits) {
			return sign + digits
		}
		return sign + digits[:decpt] + "." + digits[decpt:]
	}
	return sign + "0." + strings.Repeat("0", -decpt) + digits
}

type encoding int

const (
	encBinary encoding = iota
	encUTF8
	encASCII
)

type internedKey struct {
	enc encoding
	s   string
}

func (d *dumper) str(s string, enc encoding, hashKey bool) {
	if hashKey {
		k := internedKey{enc, s}
		if idx, ok := d.keys[k]; ok {
			d.link(idx)
			return
		}
		d.keys[k] = d.remember()
	} else {
		d.remember()
	}
	if enc == encBinary {
		d.buf = append(d.buf, '"')
		d.bytes(s)
		return
	}
	d.buf = append(d.buf, 'I', '"')
	d.bytes(s)
	d.long(1)
	d.symbol(Symbol("E"))
	if enc == encUTF8 {
		d.buf = append(d.buf, 'T')
	} else {
		d.buf = append(d.buf, 'F')
	}
}

// symbol is w_symbol; a non-ASCII symbol carries its encoding, which Ruby only allows as UTF-8 here.
func (d *dumper) symbol(s Symbol) error {
	if idx, ok := d.syms[s]; ok {
		d.buf = append(d.buf, ';')
		d.long(int64(idx))
		return nil
	}
	ascii := isASCII(string(s))
	if !ascii && !utf8.ValidString(string(s)) {
		return fmt.Errorf("%w: marshal: symbol %q is not UTF-8", ErrUnported, string(s))
	}
	if !ascii {
		d.buf = append(d.buf, 'I')
	}
	d.buf = append(d.buf, ':')
	d.bytes(string(s))
	d.syms[s] = len(d.syms)
	if !ascii {
		d.long(1)
		d.symbol(Symbol("E"))
		d.buf = append(d.buf, 'T')
	}
	return nil
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}
