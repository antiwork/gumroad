package railscache

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"
)

// testdata/fixtures.json comes from activesupport 8.1.3.1 and dalli 3.2.8 on Ruby 3.4,
// configured as production (cache_format_version 7.1, SHA256 digests, namespace REVISION).
type fixtures struct {
	Keys []struct {
		Namespace string
		Name      string // hex
		Key       string
	}
	RingKeys []string `json:"ring_keys"` // hex
	Rings    []struct {
		Servers []string
		Names   []string
		Points  int
		Chains  [][]int
	}
	Marshal []struct {
		Value json.RawMessage
		Hex   string
	}
	LoadOnly []struct {
		Hex   string
		Value json.RawMessage
	} `json:"load_only"`
	Writes []struct {
		Name        string
		Key         string
		Now         [2]int64
		ExpiresInNs *int64 `json:"expires_in_ns"`
		Value       json.RawMessage
		Flags       uint32
		TTL         int64
		Data        string
		Compressed  bool
	}
	Reads []struct {
		Label      string
		Flags      uint32
		Data       string
		Value      json.RawMessage
		Compressed bool
		Results    []struct {
			Now     [2]int64
			Expired bool
		}
	}
	Unported []struct {
		Label string
		Flags uint32
		Data  string
	}
}

func loadFixtures(t *testing.T) *fixtures {
	t.Helper()
	data, err := os.ReadFile("testdata/fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var f fixtures
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return &f
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// build turns gen_fixtures.rb's typed values into the Go values load returns.
func build(t *testing.T, raw json.RawMessage) any {
	t.Helper()
	var tv []json.RawMessage
	if err := json.Unmarshal(raw, &tv); err != nil {
		t.Fatal(err)
	}
	var tag string
	json.Unmarshal(tv[0], &tag)
	str := func(i int) string {
		var s string
		json.Unmarshal(tv[i], &s)
		return s
	}
	switch tag {
	case "nil":
		return nil
	case "true":
		return true
	case "false":
		return false
	case "int":
		n, ok := new(big.Int).SetString(str(1), 10)
		if !ok {
			t.Fatalf("bad int %s", tv[1])
		}
		if n.IsInt64() {
			return n.Int64()
		}
		return n
	case "float":
		var bits uint64
		fmt.Sscanf(str(1), "%x", &bits)
		return math.Float64frombits(bits)
	case "str":
		b := string(unhex(t, str(2)))
		switch str(1) {
		case "utf8":
			return b
		case "ascii":
			return ASCII(b)
		case "binary":
			return Binary(b)
		}
	case "sym":
		return Symbol(unhex(t, str(1)))
	case "arr":
		var items []json.RawMessage
		json.Unmarshal(tv[1], &items)
		a := make([]any, len(items))
		for i, item := range items {
			a[i] = build(t, item)
		}
		return a
	case "hash":
		var pairs [][2]json.RawMessage
		json.Unmarshal(tv[1], &pairs)
		h := make(Hash, len(pairs))
		for i, p := range pairs {
			h[i] = Pair{build(t, p[0]), build(t, p[1])}
		}
		return h
	}
	t.Fatalf("bad typed value %s", raw)
	return nil
}

// same is Ruby's eql? on these values, with NaN equal to itself.
func same(a, b any) bool {
	switch a := a.(type) {
	case float64:
		b, ok := b.(float64)
		return ok && (math.Float64bits(a) == math.Float64bits(b) || math.IsNaN(a) && math.IsNaN(b))
	case *big.Int:
		b, ok := b.(*big.Int)
		return ok && a.Cmp(b) == 0
	case []any:
		b, ok := b.([]any)
		if !ok || len(a) != len(b) {
			return false
		}
		for i := range a {
			if !same(a[i], b[i]) {
				return false
			}
		}
		return true
	case Hash:
		b, ok := b.(Hash)
		if !ok || len(a) != len(b) {
			return false
		}
		for i := range a {
			if !same(a[i].Key, b[i].Key) || !same(a[i].Value, b[i].Value) {
				return false
			}
		}
		return true
	}
	return a == b
}

func TestNormalizeKeyMatchesMemCacheStore(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.Keys {
		name := string(unhex(t, c.Name))
		got, err := normalizeKey(c.Namespace, name)
		if err != nil || got != c.Key {
			t.Errorf("normalizeKey(%q, %q)\n got %q %v\nwant %q", c.Namespace, name, got, err, c.Key)
		}
	}
	if _, err := normalizeKey("ns", ""); err == nil {
		t.Error("a blank key raises in Store#expand_and_namespace_key")
	}
}

func TestRingMatchesDalli(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.Rings {
		servers, err := parseServers(c.Servers)
		if err != nil {
			t.Fatal(err)
		}
		if len(servers) != len(c.Names) {
			t.Fatalf("%v: %d servers, want %d", c.Servers, len(servers), len(c.Names))
		}
		for i, s := range servers {
			if s.name != c.Names[i] {
				t.Errorf("server name %q, want %q", s.name, c.Names[i])
			}
		}
		r, err := newRing(servers)
		if err != nil {
			t.Fatal(err)
		}
		if len(r.points) != c.Points {
			t.Errorf("%v: %d points, want %d", c.Servers, len(r.points), c.Points)
		}
		for i, chain := range c.Chains {
			for try, want := range chain {
				key := string(unhex(t, f.RingKeys[i]))
				if got := r.candidate(key, try); got != servers[want] {
					t.Errorf("%v: key %q try %d on %s, want %s", c.Servers, key, try, got.name, c.Names[want])
				}
			}
		}
	}
}

func TestParseServersRefusesWhatDalliRefuses(t *testing.T) {
	for _, s := range []string{"[]:11211", "host:11211:1:2", "/tmp/sock:1:2", "host:08"} {
		if _, err := parseServers([]string{s}); err == nil {
			t.Errorf("%q parsed", s)
		}
	}
	if _, err := parseServers([]string{"memcached://user:pass@host"}); err == nil {
		t.Error("SASL servers aren't supported")
	}
	if s, _ := parseServers([]string{"host:011211"}); s[0].name != "host:4745" {
		t.Errorf("Integer(\"011211\") is octal, got %s", s[0].name)
	}
}

func TestDumpMatchesRubyMarshal(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.Marshal {
		v := build(t, c.Value)
		got, err := Dump(v)
		if err != nil || hex.EncodeToString(got) != c.Hex {
			t.Errorf("Dump(%s)\n got %x %v\nwant %s", c.Value, got, err, c.Hex)
		}
		loaded, err := load(unhex(t, c.Hex))
		if err != nil || !same(loaded, v) {
			t.Errorf("load(%s) = %#v %v, want %#v", c.Hex, loaded, err, v)
		}
	}
}

func TestLoadFollowsLinksAndRefusesOtherObjects(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.LoadOnly {
		got, err := load(unhex(t, c.Hex))
		if c.Value == nil {
			if !errors.Is(err, ErrUnported) {
				t.Errorf("load(%s) = %#v %v, want ErrUnported", c.Hex, got, err)
			}
			continue
		}
		if want := build(t, c.Value); err != nil || !same(got, want) {
			t.Errorf("load(%s) = %#v %v, want %#v", c.Hex, got, err, want)
		}
	}
}

func TestDumpRefusesValuesRubyCantHold(t *testing.T) {
	for _, v := range []any{map[string]any{"a": 1}, []byte("x"), Symbol("\xff"), struct{}{}, []any{(*big.Int)(nil)}} {
		if _, err := Dump(v); !errors.Is(err, ErrUnported) {
			t.Errorf("Dump(%#v) = %v", v, err)
		}
	}
	if got, want := mustDump(t, []int{3, 41, 187}), mustDump(t, []any{3, 41, 187}); !bytes.Equal(got, want) {
		t.Errorf("a typed slice dumps as an Array: %x, want %x", got, want)
	}
}

func mustDump(t *testing.T, v any) []byte {
	t.Helper()
	b, err := Dump(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestWriteMatchesStoreWrite(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.Writes {
		key, err := normalizeKey("24fb9aed6a64", c.Name)
		if err != nil || key != c.Key {
			t.Errorf("key %q, want %q", key, c.Key)
		}
		var expiresIn time.Duration
		if c.ExpiresInNs != nil {
			expiresIn = time.Duration(*c.ExpiresInNs)
		}
		data, extras, err := encodeWrite(build(t, c.Value), expiresIn, time.Unix(c.Now[0], c.Now[1]))
		if err != nil {
			t.Errorf("%s: %v", c.Name, err)
			continue
		}
		if c.Compressed {
			// Ruby's deflate bytes aren't Go's, so check what Rails' read of them would give.
			e, err := decodeStored(binary.BigEndian.Uint32(extras[:4]), data)
			if err != nil || e.typ&typeCompressed == 0 {
				t.Errorf("%s: %v, type %#x", c.Name, err, e.typ)
				continue
			}
			if got, err := e.value(); err != nil || !same(got, build(t, c.Value)) {
				t.Errorf("%s: read back %#v %v", c.Name, got, err)
			}
			continue
		}
		flags, ttl := binary.BigEndian.Uint32(extras[:4]), int64(binary.BigEndian.Uint32(extras[4:]))
		if hex.EncodeToString(data) != c.Data || flags != c.Flags || ttl != c.TTL {
			t.Errorf("%s\n got %x flags %d ttl %d\nwant %s flags %d ttl %d", c.Name, data, flags, ttl, c.Data, c.Flags, c.TTL)
		}
	}
}

func TestReadMatchesStoreRead(t *testing.T) {
	f := loadFixtures(t)
	compressed := 0
	for _, c := range f.Reads {
		e, err := decodeStored(c.Flags, unhex(t, c.Data))
		if strings.HasSuffix(c.Label, ":v1") {
			if !errors.Is(err, ErrUnported) {
				t.Errorf("%s: a versioned entry is ErrUnported, got %v", c.Label, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.Label, err)
			continue
		}
		if c.Compressed {
			compressed++
		}
		want := build(t, c.Value)
		for _, r := range c.Results {
			now := rubyTime(time.Unix(r.Now[0], r.Now[1]))
			if e.expired(now) != r.Expired {
				t.Errorf("%s at %v: expired %v, want %v", c.Label, r.Now, !r.Expired, r.Expired)
			}
		}
		if got, err := e.value(); err != nil || !same(got, want) {
			t.Errorf("%s: %#v %v, want %#v", c.Label, got, err, want)
		}
	}
	if compressed == 0 {
		t.Error("no compressed reads in the fixtures")
	}
}

func TestUnportedEntries(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.Unported {
		e, err := decodeStored(c.Flags, unhex(t, c.Data))
		if err == nil {
			_, err = e.value()
		}
		if !errors.Is(err, ErrUnported) {
			t.Errorf("%s: %v, want ErrUnported", c.Label, err)
		}
	}
}

func TestWriteRefusesANegativeExpiry(t *testing.T) {
	s, err := New([]string{"127.0.0.1:1"}, "ns", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Write(t.Context(), "k", 1, -time.Second); err == nil {
		t.Error("raise_on_invalid_cache_expiration_time raises on a negative expires_in")
	}
}

// An encoding ivar whose value is another ivar-wrapped string counts toward the nesting cap.
func TestNestedEncodingValuesHitTheDepthLimit(t *testing.T) {
	data := "\x04\x08" + strings.Repeat("I\"\x00\x06:\x06E", 1000) + "T"
	// Without the limit the innermost value is read as a non-boolean encoding instead.
	if _, err := load([]byte(data)); !errors.Is(err, ErrUnported) || !strings.Contains(err.Error(), "nesting too deep") {
		t.Fatalf("got %v", err)
	}
}
