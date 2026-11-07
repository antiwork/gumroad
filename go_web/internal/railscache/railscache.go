// Package railscache reads and writes Rails.cache entries in memcached as production's
// MemCacheStore does, byte for byte: activesupport 8.1.3.1's Coder (cache_format_version
// 7.1) under Dalli 3.2.8's Marshal and binary protocol.
package railscache

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// ErrUnported wraps every entry this package can't decode, or can't encode as Rails would.
// Rails' own read or write is the fallback.
var ErrUnported = errors.New("railscache: unported cache entry")

// ErrServerDown is a key's server refusing or timing out a connection, or one that did
// within the last 30 seconds (Dalli's down_retry_delay).
var ErrServerDown = errors.New("railscache: memcached server down")

// Store::MAX_KEY_SIZE, which MemCacheStore keeps.
const maxKeySize = 250

// Store::DEFAULT_COMPRESS_LIMIT, the compress_threshold production leaves in place.
const compressThreshold = 1024

// Dalli's ValueSerializer::FLAG_SERIALIZED and ValueCompressor::FLAG_COMPRESSED.
const (
	flagSerialized = 0x1
	flagCompressed = 0x2
)

// Coder's SIGNATURE, type codes and COMPRESSED_FLAG.
const (
	typeObject     = 0x01
	typeUTF8       = 0x02
	typeBinary     = 0x03
	typeASCII      = 0x04
	typeCompressed = 0x80
	headerLen      = 15 // SIGNATURE, then "CEl<"
)

var signature = []byte{0x00, 0x11}

// Dalli::Protocol::TtlSanitizer::MAX_ACCEPTABLE_EXPIRATION_INTERVAL.
const maxRelativeTTL = 30 * 24 * 60 * 60

// Store is Rails.cache: MemCacheStore.new(*servers, namespace: namespace).
type Store struct {
	// failover is Dalli's default rehash past an unreachable server
	// (Ring#server_from_continuum). Off, as New leaves it, such a key fails with
	// ErrServerDown and Rails, which does fail over, serves it instead.
	failover bool
	// clock is Time.now for Entry#expires_at and expiry checks; nil is the real clock.
	clock func() time.Time

	namespace atomic.Pointer[string]
	timeout   time.Duration
	ring      *ring
}

// New takes the server strings Dalli does ("host", "host:port", "host:port:weight",
// comma-separated lists) and the namespace (production's REVISION; "" for none). timeout
// bounds each operation's connect and round trip.
func New(servers []string, namespace string, timeout time.Duration) (*Store, error) {
	if timeout <= 0 {
		return nil, fmt.Errorf("railscache: timeout must be positive")
	}
	parsed, err := parseServers(servers)
	if err != nil {
		return nil, err
	}
	r, err := newRing(parsed)
	if err != nil {
		return nil, err
	}
	s := &Store{timeout: timeout, ring: r}
	s.namespace.Store(&namespace)
	return s, nil
}

// Namespace is the REVISION the keys are namespaced under.
func (s *Store) Namespace() string { return *s.namespace.Load() }

// SetNamespace moves later reads and writes to another REVISION's keys.
func (s *Store) SetNamespace(namespace string) { s.namespace.Store(&namespace) }

// Close drops idle connections.
func (s *Store) Close() {
	for _, srv := range s.ring.servers {
		for drained := false; !drained; {
			select {
			case c := <-srv.idle:
				c.Close()
			default:
				drained = true
			}
		}
	}
}

func (s *Store) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// rubyTime is Time#to_f: nanoseconds divided as a double, which rounds differently from
// adding the fraction to the seconds.
func rubyTime(t time.Time) float64 { return float64(t.UnixNano()) / 1e9 }

// normalizeKey is MemCacheStore#normalize_key for a String key: Store#namespace_key, then
// each byte of ESCAPE_KEY_CHARS as "%" and its unpadded uppercase hex, then
// Store#truncate_key with ActiveSupport::Digest (SHA256 under load_defaults 7.0+). Dalli
// sends that unchanged: it has no namespace and the key is never over 250 bytes.
func normalizeKey(namespace, name string) (string, error) {
	if name == "" {
		return "", errors.New("railscache: key cannot be blank")
	}
	if namespace != "" {
		name = namespace + ":" + name
	}
	var b strings.Builder
	for i := 0; i < len(name); i++ {
		c := name[i]
		if c <= 0x20 || c == '%' || c >= 0x7f {
			b.WriteByte('%')
			b.WriteString(strings.ToUpper(strconv.FormatUint(uint64(c), 16)))
		} else {
			b.WriteByte(c)
		}
	}
	key := b.String()
	if len(key) > maxKeySize {
		sum := sha256.Sum256([]byte(key))
		suffix := ":hash:" + hex.EncodeToString(sum[:])[:32]
		key = key[:maxKeySize-len(suffix)] + suffix
	}
	return key, nil
}

// Read is Rails.cache.read(name): the value (in marshal.go's types), and whether there
// was an unexpired entry. An expired entry is deleted, as Store#read does.
func (s *Store) Read(ctx context.Context, name string) (any, bool, error) {
	key, err := normalizeKey(s.Namespace(), name)
	if err != nil {
		return nil, false, err
	}
	resp, err := s.do(ctx, key, opGet, nil, nil)
	if err != nil {
		return nil, false, err
	}
	switch resp.status {
	case statusOK:
	case statusNotFound:
		return nil, false, nil
	default:
		return nil, false, fmt.Errorf("railscache: get status %d", resp.status)
	}
	var flags uint32
	if len(resp.extras) >= 4 {
		flags = binary.BigEndian.Uint32(resp.extras)
	}
	e, err := decodeStored(flags, resp.value)
	if err != nil {
		return nil, false, err
	}
	if e.expired(rubyTime(s.now())) {
		// MemCacheStore#delete_entry ignores Dalli errors.
		s.do(ctx, key, opDelete, nil, nil)
		return nil, false, nil
	}
	v, err := e.value()
	if err != nil {
		return nil, false, err
	}
	return v, true, nil
}

// Write is Rails.cache.write(name, value, expires_in:). An expiresIn of 0 means no
// expires_in, not Ruby's expires_in: 0 (an entry that is born expired).
func (s *Store) Write(ctx context.Context, name string, value any, expiresIn time.Duration) error {
	if expiresIn < 0 {
		// raise_on_invalid_cache_expiration_time is on (new_framework_defaults_7_1.rb).
		return fmt.Errorf("railscache: Cache expiration time is invalid, cannot be negative: %v", expiresIn)
	}
	key, err := normalizeKey(s.Namespace(), name)
	if err != nil {
		return err
	}
	data, extras, err := encodeWrite(value, expiresIn, s.now())
	if err != nil {
		return err
	}
	resp, err := s.do(ctx, key, opSet, extras, data)
	if err != nil {
		return err
	}
	if resp.status != statusOK {
		return fmt.Errorf("railscache: set status %d", resp.status)
	}
	return nil
}

// Delete is Rails.cache.delete(name).
func (s *Store) Delete(ctx context.Context, name string) error {
	key, err := normalizeKey(s.Namespace(), name)
	if err != nil {
		return err
	}
	resp, err := s.do(ctx, key, opDelete, nil, nil)
	if err != nil {
		return err
	}
	if resp.status != statusOK && resp.status != statusNotFound {
		return fmt.Errorf("railscache: delete status %d", resp.status)
	}
	return nil
}

func (s *Store) do(ctx context.Context, key string, op byte, extras, value []byte) (response, error) {
	deadline := time.Now().Add(s.timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	srv, c, err := s.conn(ctx, key, deadline)
	if err != nil {
		return response{}, err
	}
	resp, err := srv.roundTrip(ctx, c, deadline, op, key, extras, value)
	// A pooled connection memcached dropped: Dalli's perform reconnects and retries too. A
	// reply that ran out the clock is a slow server, not a dropped connection.
	if err != nil && c.reused && ctx.Err() == nil && !errors.Is(err, os.ErrDeadlineExceeded) && time.Now().Before(deadline) {
		dialCtx, cancel := context.WithDeadline(ctx, deadline)
		defer cancel()
		if c, err = srv.dial(dialCtx, ctx, time.Now()); err != nil {
			return response{}, err
		}
		return srv.roundTrip(ctx, c, deadline, op, key, extras, value)
	}
	return resp, err
}

// conn is Ring#server_for_key: the key's server, or with failover the first reachable of
// Ring#server_from_continuum's rehashes. A single server never fails over.
func (s *Store) conn(ctx context.Context, key string, deadline time.Time) (*server, *conn, error) {
	tries := 1
	if s.failover && s.ring.points != nil {
		tries = failoverTries
	}
	dialCtx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	var err error
	for try := range tries {
		srv := s.ring.candidate(key, try)
		var c *conn
		if c, err = srv.conn(dialCtx, ctx, time.Now()); err == nil {
			return srv, c, nil
		}
		if dialCtx.Err() != nil {
			break
		}
	}
	return nil, nil, err
}

// encodeWrite is Store#write's Entry through MemCacheStore#write_serialized_entry and
// Dalli's set: the stored bytes, and the flags and exptime extras.
func encodeWrite(value any, expiresIn time.Duration, now time.Time) ([]byte, []byte, error) {
	expiresAt := -1.0
	var ttl int64
	if expiresIn > 0 {
		// Entry#initialize: expires_in.to_f + Time.now.to_f.
		expiresAt = expiresIn.Seconds() + rubyTime(now)
		ttl = int64(expiresIn / time.Second)
		if ttl > maxRelativeTTL && ttl <= now.Unix() {
			ttl += now.Unix()
		}
	}
	coded, err := encodeEntry(value, expiresAt)
	if err != nil {
		return nil, nil, err
	}
	data, _ := Dump(Binary(coded))
	extras := make([]byte, 8)
	binary.BigEndian.PutUint32(extras, flagSerialized)
	binary.BigEndian.PutUint32(extras[4:], uint32(ttl))
	return data, extras, nil
}

// encodeEntry is Coder#dump_compressed for an Entry without a version. Strings go in raw
// with their encoding's type code; anything else is Marshal.dump.
func encodeEntry(value any, expiresAt float64) ([]byte, error) {
	var typ byte
	var payload []byte
	switch v := value.(type) {
	case string:
		typ, payload = typeUTF8, []byte(v)
	case ASCII:
		typ, payload = typeASCII, []byte(v)
	case Binary:
		typ, payload = typeBinary, []byte(v)
	default:
		var err error
		if payload, err = Dump(value); err != nil {
			return nil, err
		}
		typ = typeObject
	}
	if len(payload) >= compressThreshold {
		// Coder#try_compress. Go's zlib bytes differ from Ruby's, but Coder#load inflates either.
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(payload)
		w.Close()
		if buf.Len() < len(payload) {
			typ |= typeCompressed
			payload = buf.Bytes()
		}
	}
	b := make([]byte, headerLen, headerLen+len(payload))
	copy(b, signature)
	b[2] = typ
	binary.LittleEndian.PutUint64(b[3:], math.Float64bits(expiresAt))
	binary.LittleEndian.PutUint32(b[11:], math.MaxUint32) // no version: length -1
	return append(b, payload...), nil
}

type entry struct {
	typ       byte
	expiresAt float64
	payload   []byte
}

// expired is Entry#expired?; Coder#load treats a negative expires_at as none.
func (e entry) expired(now float64) bool {
	return !(e.expiresAt < 0) && e.expiresAt <= now
}

// decodeStored is Dalli's ValueMarshaller#retrieve then Coder#load, up to the payload.
func decodeStored(flags uint32, data []byte) (entry, error) {
	if flags&flagCompressed != 0 {
		var err error
		if data, err = inflate(data); err != nil {
			return entry{}, err
		}
	}
	if flags&flagSerialized != 0 {
		v, err := load(data)
		if err != nil {
			return entry{}, err
		}
		switch v := v.(type) {
		case Binary:
			data = []byte(v)
		case string:
			data = []byte(v)
		case ASCII:
			data = []byte(v)
		default:
			return entry{}, fmt.Errorf("%w: Dalli value is a %T", ErrUnported, v)
		}
	}
	if len(data) < headerLen || !bytes.HasPrefix(data, signature) {
		// SerializerWithFallback's 7.0 and pre-7.1 formats.
		return entry{}, fmt.Errorf("%w: no Coder signature", ErrUnported)
	}
	e := entry{
		typ:       data[2],
		expiresAt: math.Float64frombits(binary.LittleEndian.Uint64(data[3:])),
	}
	// A version is only written by a caller that reads with one (version:, or a record's
	// cache_version), and Entry#mismatched? would then compare them. A String-key read
	// ignores it, so serving it here would hide a stale entry.
	if n := int32(binary.LittleEndian.Uint32(data[11:])); n >= 0 {
		return entry{}, fmt.Errorf("%w: versioned entry", ErrUnported)
	}
	e.payload = data[headerLen:]
	return e, nil
}

// value is LazyEntry#value.
func (e entry) value() (any, error) {
	p := e.payload
	if e.typ&typeCompressed != 0 {
		var err error
		if p, err = inflate(p); err != nil {
			return nil, err
		}
	}
	switch e.typ &^ typeCompressed {
	case typeUTF8:
		return string(p), nil
	case typeBinary:
		return Binary(p), nil
	case typeASCII:
		return ASCII(p), nil
	}
	// Any other type goes to SerializerWithFallback#load, which takes Marshal by its prefix.
	if !bytes.HasPrefix(p, []byte{4, 8}) {
		return nil, fmt.Errorf("%w: payload type %#x", ErrUnported, e.typ)
	}
	return load(p)
}

// inflate is Zlib::Inflate.inflate, refusing output no cache entry worth porting reaches.
func inflate(data []byte) ([]byte, error) {
	r, err := zlib.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: zlib: %v", ErrUnported, err)
	}
	out, err := io.ReadAll(io.LimitReader(r, maxBodyLen+1))
	if err != nil {
		return nil, fmt.Errorf("%w: zlib: %v", ErrUnported, err)
	}
	if len(out) > maxBodyLen {
		return nil, fmt.Errorf("%w: inflates past %d bytes", ErrUnported, maxBodyLen)
	}
	return out, nil
}
