package railscache

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// GO_WEB_MEMCACHED_TEST lists two or more memcached servers, e.g.
// "127.0.0.1:11311,127.0.0.1:11312". These tests skip without it.
func liveStore(t *testing.T, extra ...string) *Store {
	t.Helper()
	env := os.Getenv("GO_WEB_MEMCACHED_TEST")
	if env == "" {
		t.Skip("GO_WEB_MEMCACHED_TEST is not set")
	}
	servers := append(strings.Split(env, ","), extra...)
	if len(servers) < 2 {
		t.Fatal("GO_WEB_MEMCACHED_TEST needs two servers to exercise the ring")
	}
	ns := make([]byte, 6)
	rand.Read(ns)
	s, err := New(servers, "railscache-test-"+hex.EncodeToString(ns), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// rawGet asks one server for a normalized key, bypassing the ring.
func rawGet(t *testing.T, srv *server, key string) (response, bool) {
	t.Helper()
	ctx := t.Context()
	c, err := srv.conn(ctx, ctx, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	resp, err := srv.roundTrip(ctx, c, time.Now().Add(time.Second), opGet, key, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	return resp, resp.status == statusOK
}

// remainingTTL is the meta protocol's view of an item's exptime: -1 for none.
func remainingTTL(t *testing.T, srv *server, key string) int {
	t.Helper()
	c, err := net.DialTimeout("tcp", srv.addr, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	fmt.Fprintf(c, "mg %s t\r\n", key)
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	f := strings.Fields(line)
	if len(f) != 2 || f[0] != "HD" || !strings.HasPrefix(f[1], "t") {
		t.Fatalf("mg %s: %q", key, line)
	}
	n, _ := strconv.Atoi(f[1][1:])
	return n
}

func (s *Store) key(t *testing.T, name string) string {
	t.Helper()
	k, err := normalizeKey(s.Namespace(), name)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestLiveRoundTrip(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	values := []any{
		int64(123), []any{int64(3), int64(41), int64(187)}, nil, true, false, 1.5, "text", "é", ASCII("123"),
		Binary("\x00\xff"), Symbol("sym"), new(big.Int).Lsh(big.NewInt(1), 64),
		Hash{{"count", int64(3)}, {Symbol("count"), int64(4)}}, []any{Hash{{"id", int64(1)}}, Hash{{"id", int64(2)}}},
	}
	for i, v := range values {
		name := fmt.Sprintf("round trip %d é\t%%", i)
		if err := s.Write(ctx, name, v, time.Minute); err != nil {
			t.Fatal(err)
		}
		got, found, err := s.Read(ctx, name)
		if err != nil || !found || !same(got, v) {
			t.Errorf("Read(%q) = %#v %v %v, want %#v", name, got, found, err, v)
		}
	}
	if _, found, err := s.Read(ctx, "never written"); found || err != nil {
		t.Errorf("a missing key reads as a miss, got %v %v", found, err)
	}
	if err := s.Delete(ctx, "round trip 0 é\t%"); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := s.Read(ctx, "round trip 0 é\t%"); found {
		t.Error("Delete left the entry")
	}
	big := strings.Repeat("x", compressThreshold)
	if err := s.Write(ctx, "deflated", big, 0); err != nil {
		t.Fatal(err)
	}
	if got, found, err := s.Read(ctx, "deflated"); err != nil || !found || got != big {
		t.Errorf("a deflated value reads back as %d bytes, %v %v", len(fmt.Sprint(got)), found, err)
	}
}

func TestLiveStoredItemMatchesStoreWrite(t *testing.T) {
	s := liveStore(t)
	s.SetNamespace("24fb9aed6a64")
	ctx := t.Context()
	checked := 0
	for _, c := range loadFixtures(t).Writes {
		if c.Compressed || c.TTL > maxRelativeTTL {
			continue // absolute exptimes from the fixture's clock would eventually lie in the past
		}
		s.clock = func() time.Time { return time.Unix(c.Now[0], c.Now[1]) }
		var expiresIn time.Duration
		if c.ExpiresInNs != nil {
			expiresIn = time.Duration(*c.ExpiresInNs)
		}
		if err := s.Write(ctx, c.Name, build(t, c.Value), expiresIn); err != nil {
			t.Fatal(err)
		}
		home := s.ring.candidate(c.Key, 0)
		for _, srv := range s.ring.servers {
			resp, found := rawGet(t, srv, c.Key)
			if found != (srv == home) {
				t.Errorf("%s: on %s = %v, home is %s", c.Name, srv.name, found, home.name)
			}
			if !found {
				continue
			}
			if flags := binary.BigEndian.Uint32(resp.extras); flags != c.Flags || hex.EncodeToString(resp.value) != c.Data {
				t.Errorf("%s: stored flags %d %x, want %d %s", c.Name, flags, resp.value, c.Flags, c.Data)
			}
			ttl := remainingTTL(t, srv, c.Key)
			if c.TTL == 0 && ttl != -1 || c.TTL > 0 && (ttl > int(c.TTL) || ttl < int(c.TTL)-2) {
				t.Errorf("%s: remaining ttl %d, sent %d", c.Name, ttl, c.TTL)
			}
		}
		checked++
	}
	if checked < 20 {
		t.Fatalf("only %d fixtures checked", checked)
	}
}

// serverTime is memcached's own clock, which an absolute exptime is measured against.
func serverTime(t *testing.T, srv *server) int64 {
	t.Helper()
	c, err := net.DialTimeout("tcp", srv.addr, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	fmt.Fprint(c, "stats\r\n")
	r := bufio.NewReader(c)
	for {
		line, err := r.ReadString('\n')
		if err != nil || strings.HasPrefix(line, "END") {
			t.Fatalf("no STAT time: %v", err)
		}
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "STAT time "); ok {
			n, _ := strconv.ParseInt(v, 10, 64)
			return n
		}
	}
}

func TestLiveTTLOverThirtyDaysIsATimestamp(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	written := time.Now().Unix()
	if err := s.Write(ctx, "long", int64(1), 31*24*time.Hour); err != nil {
		t.Fatal(err)
	}
	key := s.key(t, "long")
	srv := s.ring.candidate(key, 0)
	want := written + 31*24*3600 - serverTime(t, srv)
	if ttl := int64(remainingTTL(t, srv, key)); ttl < want-3 || ttl > want+3 {
		t.Errorf("remaining ttl %d, want %d (now + ttl as a timestamp)", ttl, want)
	}
}

func TestLiveEveryKeyLandsOnItsRingServer(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	counts := map[*server]int{}
	for i := range 2000 {
		name := fmt.Sprintf("placement/%d", i)
		if err := s.Write(ctx, name, int64(i), time.Minute); err != nil {
			t.Fatal(err)
		}
		key := s.key(t, name)
		home := s.ring.candidate(key, 0)
		for _, srv := range s.ring.servers {
			if _, found := rawGet(t, srv, key); found != (srv == home) {
				t.Fatalf("%s on %s = %v, home is %s", key, srv.name, found, home.name)
			}
		}
		counts[home]++
	}
	for _, srv := range s.ring.servers {
		if counts[srv] < 2000/len(s.ring.servers)/2 {
			t.Errorf("%s got %d of 2000 keys", srv.name, counts[srv])
		}
	}
}

func TestLiveExpiredEntryReadsAsMissAndIsDeleted(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	s.clock = func() time.Time { return time.Now().Add(-2 * time.Hour) }
	if err := s.Write(ctx, "stale", int64(1), time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := s.Write(ctx, "fresh", int64(2), 3*time.Hour); err != nil {
		t.Fatal(err)
	}
	s.clock = nil
	key := s.key(t, "stale")
	if _, found := rawGet(t, s.ring.candidate(key, 0), key); !found {
		t.Fatal("memcached's own ttl (60s) hasn't run out, so the item is still there")
	}
	if v, found, err := s.Read(ctx, "stale"); found || err != nil {
		t.Errorf("an expired Entry reads as a miss, got %v %v %v", v, found, err)
	}
	if _, found := rawGet(t, s.ring.candidate(key, 0), key); found {
		t.Error("Store#read deletes an expired entry")
	}
	if v, found, err := s.Read(ctx, "fresh"); !found || err != nil || v != int64(2) {
		t.Errorf("fresh = %v %v %v", v, found, err)
	}
}

func TestLiveDownServer(t *testing.T) {
	s := liveStore(t, "127.0.0.1:1") // nothing listens there: connection refused
	ctx := t.Context()
	dead := s.ring.servers[len(s.ring.servers)-1]
	var names []string
	for i := 0; len(names) < 20; i++ {
		name := fmt.Sprintf("failover/%d", i)
		if s.ring.candidate(s.key(t, name), 0) == dead {
			names = append(names, name)
		}
	}
	for _, name := range names {
		if err := s.Write(ctx, name, int64(1), time.Minute); !errors.Is(err, ErrServerDown) {
			t.Fatalf("without failover a dead server is ErrServerDown, got %v", err)
		}
	}

	s.failover = true
	for _, name := range names {
		if err := s.Write(ctx, name, name, time.Minute); err != nil {
			t.Fatal(err)
		}
		key := s.key(t, name)
		var home *server
		for try := range failoverTries {
			if home = s.ring.candidate(key, try); home != dead {
				break
			}
		}
		if _, found := rawGet(t, home, key); !found {
			t.Errorf("%s isn't on %s, Ring#server_from_continuum's first live server", name, home.name)
		}
		if v, found, err := s.Read(ctx, name); !found || err != nil || v != name {
			t.Errorf("Read(%q) = %v %v %v", name, v, found, err)
		}
	}
}

func TestLiveContextCancellation(t *testing.T) {
	s := liveStore(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, _, err := s.Read(ctx, "k"); err == nil {
		t.Error("a cancelled context fails the read")
	}
	if _, _, err := s.Read(t.Context(), "k"); err != nil {
		t.Errorf("cancelling a caller's context must not mark the server down: %v", err)
	}
}

func TestLiveRetriesADroppedIdleConnection(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	if err := s.Write(ctx, "k", int64(1), time.Minute); err != nil {
		t.Fatal(err)
	}
	srv := s.ring.candidate(s.key(t, "k"), 0)
	c := <-srv.idle
	c.Conn.Close()
	srv.idle <- c
	if v, found, err := s.Read(ctx, "k"); !found || err != nil || v != int64(1) {
		t.Errorf("Read over a dropped pooled connection = %v %v %v", v, found, err)
	}
}

func TestLiveConcurrentUse(t *testing.T) {
	s := liveStore(t)
	ctx := t.Context()
	var wg sync.WaitGroup
	for g := range 8 {
		wg.Go(func() {
			for i := range 200 {
				name := fmt.Sprintf("concurrent/%d/%d", g, i%20)
				if err := s.Write(ctx, name, int64(i), time.Minute); err != nil {
					t.Error(err)
					return
				}
				if _, found, err := s.Read(ctx, name); !found || err != nil {
					t.Errorf("%s: %v %v", name, found, err)
					return
				}
			}
		})
	}
	wg.Wait()
}
