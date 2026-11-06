package flipper

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

type fakeHash struct {
	mu     sync.Mutex
	fields map[string]string
	err    error
	keys   []string
	block  chan struct{} // when set, reads wait for it to close
}

func (h *fakeHash) HGetAll(ctx context.Context, key string) *redis.MapStringStringCmd {
	h.mu.Lock()
	h.keys = append(h.keys, key)
	fields, err, block := h.fields, h.err, h.block
	h.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return redis.NewMapStringStringResult(nil, ctx.Err())
		}
	}
	return redis.NewMapStringStringResult(fields, err)
}

func (h *fakeHash) reads() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.keys)
}

func newTestFlag(hash *fakeHash, now *time.Time) *Flag {
	f := New(hash, "a_flag")
	f.now = func() time.Time { return *now }
	f.random = func() float64 { return 0.5 }
	return f
}

func TestFlipperFlagReadsTheGatesFlipperRedisStores(t *testing.T) {
	cases := map[string]struct {
		fields map[string]string
		want   bool
	}{
		"enabled":                 {map[string]string{"boolean": "true"}, true},
		"enabled as 1":            {map[string]string{"boolean": "1"}, true},
		"never set":               {map[string]string{}, false},
		"actor only":              {map[string]string{"actors/User;1": "1"}, false},
		"percentage of actors":    {map[string]string{"percentage_of_actors": "100"}, false},
		"percentage of time 60":   {map[string]string{"percentage_of_time": "60"}, true},
		"percentage of time 50":   {map[string]string{"percentage_of_time": "50"}, false},
		"percentage of time 50.5": {map[string]string{"percentage_of_time": "50.5"}, true},
	}
	for name, tc := range cases {
		now := time.Unix(1792001956, 0)
		hash := &fakeHash{fields: tc.fields}
		got, err := newTestFlag(hash, &now).Active(context.Background())
		if err != nil || got != tc.want {
			t.Errorf("%s: active() = %v, %v; want %v", name, got, err, tc.want)
		}
		if len(hash.keys) != 1 || hash.keys[0] != "a_flag" {
			t.Errorf("%s: read %v", name, hash.keys)
		}
	}
}

func TestFlipperFlagCachesBrieflyAndFallsBackToItsLastRead(t *testing.T) {
	now := time.Unix(1792001956, 0)
	hash := &fakeHash{fields: map[string]string{"boolean": "true"}}
	flag := newTestFlag(hash, &now)
	ctx := context.Background()

	flag.Active(ctx)
	now = now.Add(flagCacheTTL - time.Millisecond)
	if on, _ := flag.Active(ctx); !on || len(hash.keys) != 1 {
		t.Fatalf("a fresh read went to Redis again: %v, %d reads", on, len(hash.keys))
	}

	now = now.Add(time.Second)
	hash.err = errors.New("i/o timeout")
	if on, err := flag.Active(ctx); !on || err != nil || len(hash.keys) != 2 {
		t.Fatalf("a failed read must use the last good one: %v, %v, %d reads", on, err, len(hash.keys))
	}

	if on, _ := flag.Active(ctx); !on || len(hash.keys) != 2 {
		t.Fatalf("Redis was retried within the backoff: %d reads", len(hash.keys))
	}

	now = now.Add(flagRetryBackoff)
	hash.err, hash.fields = nil, map[string]string{}
	if on, _ := flag.Active(ctx); on || len(hash.keys) != 3 {
		t.Fatalf("a stale value outlived the next successful read: %d reads", len(hash.keys))
	}
}

func TestFlipperFlagRaisesWithoutAnyGoodRead(t *testing.T) {
	now := time.Unix(1792001956, 0)
	_, err := newTestFlag(&fakeHash{err: errors.New("connection refused")}, &now).Active(context.Background())
	if err == nil {
		t.Fatal("an unknown flag read as known")
	}
}

func TestFlipperFlagHasOneReadInFlight(t *testing.T) {
	now := time.Unix(1792001956, 0)
	hash := &fakeHash{fields: map[string]string{"boolean": "true"}, block: make(chan struct{})}
	flag := newTestFlag(hash, &now)
	ctx := context.Background()

	// With nothing known, every caller waits for the one read.
	var wg sync.WaitGroup
	results := make(chan bool, 8)
	for range 8 {
		wg.Go(func() {
			on, err := flag.Active(ctx)
			results <- on && err == nil
		})
	}
	waitFor(t, func() bool { return hash.reads() == 1 })
	close(hash.block)
	wg.Wait()
	close(results)
	for ok := range results {
		if !ok {
			t.Fatal("a waiting caller didn't get the read's value")
		}
	}
	if n := hash.reads(); n != 1 {
		t.Fatalf("%d reads", n)
	}

	// Once known, callers keep the last value while one refresh runs.
	now = now.Add(flagCacheTTL)
	hash.mu.Lock()
	hash.block = make(chan struct{})
	hash.mu.Unlock()
	refreshed := make(chan struct{})
	go func() {
		flag.Active(ctx)
		close(refreshed)
	}()
	waitFor(t, func() bool { return hash.reads() == 2 })
	for range 4 {
		if on, err := flag.Active(ctx); !on || err != nil {
			t.Fatalf("active() during a refresh = %v, %v", on, err)
		}
	}
	close(hash.block)
	<-refreshed
	if n := hash.reads(); n != 2 {
		t.Fatalf("%d reads", n)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

// Flipper::Typecast.to_number reads a string without a dot with to_i; a Bignum opens the
// gate whenever it is positive, exponent or not.
func TestFlipperNumberIsTypecastToNumber(t *testing.T) {
	cases := map[string]float64{"50": 50, " 50": 50, "12.5": 12.5, "abc": 0, "": 0, "1e2": 1}
	for s, want := range cases {
		if got := flipperNumber(s); got != want {
			t.Errorf("flipperNumber(%q) = %v, want %v", s, got, want)
		}
	}
	for s, opens := range map[string]bool{"99999999999999999999": true, "99999999999999999999e-30": true, "-99999999999999999999": false} {
		state := &flagState{percentageOfTime: flipperNumber(s)}
		f := &Flag{random: func() float64 { return 0.999999 }}
		if got, _ := f.open(state, ""); got != opens {
			t.Errorf("%q opens = %v, want %v", s, got, opens)
		}
	}
}

// The read runs detached, so the reader that started it leaving fails no one waiting.
func TestFlipperFlagOutlivesTheReaderThatStartedIt(t *testing.T) {
	now := time.Unix(1792001956, 0)
	hash := &fakeHash{fields: map[string]string{"boolean": "true"}, block: make(chan struct{})}
	flag := newTestFlag(hash, &now)
	first, leave := context.WithCancel(context.Background())
	go flag.Active(first)
	waitFor(t, func() bool { return hash.reads() == 1 })

	waiter := make(chan error, 1)
	go func() {
		on, err := flag.Active(context.Background())
		if err == nil && !on {
			err = errors.New("read as off")
		}
		waiter <- err
	}()
	leave()
	close(hash.block)
	if err := <-waiter; err != nil {
		t.Fatalf("the waiting reader got %v", err)
	}
	if n := hash.reads(); n != 1 {
		t.Fatalf("%d reads", n)
	}
}

// Flipper evaluates a set expression gate even without an actor, after the boolean gate
// and before percentage_of_time; Go can't, so the flag is unknown.
func TestFlipperFlagFailsClosedOnAnExpressionGate(t *testing.T) {
	expression := `{"Equal":[{"Property":["plan"]},"basic"]}`
	cases := map[string]struct {
		fields  map[string]string
		on      bool
		unknown bool
	}{
		"expression":                 {map[string]string{"expression": expression}, false, true},
		"expression and time":        {map[string]string{"expression": expression, "percentage_of_time": "100"}, false, true},
		"boolean wins":               {map[string]string{"boolean": "true", "expression": expression}, true, false},
		"empty expression":           {map[string]string{"expression": "{}"}, false, false},
		"null expression":            {map[string]string{"expression": "null"}, false, false},
		"expression Ruby raises on":  {map[string]string{"expression": "{"}, false, true},
		"no expression, time at 100": {map[string]string{"percentage_of_time": "100"}, true, false},
	}
	for name, tc := range cases {
		now := time.Unix(1792001956, 0)
		on, err := newTestFlag(&fakeHash{fields: tc.fields}, &now).Active(context.Background())
		if on != tc.on || errors.Is(err, ErrUnevaluable) != tc.unknown || (err != nil) != tc.unknown {
			t.Errorf("%s: active() = %v, %v", name, on, err)
		}
	}
}

func TestActorGatesFollowFlipper(t *testing.T) {
	mr := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	flag := func(name string, fields map[string]string) *Flag {
		for k, v := range fields {
			mr.HSet(name, k, v)
		}
		return New(client, name)
	}
	ctx := context.Background()
	check := func(f *Flag, actor string, want bool, wantErr error) {
		t.Helper()
		got, err := f.ActiveFor(ctx, actor)
		if got != want || !errors.Is(err, wantErr) {
			t.Errorf("%s for %s = %v, %v; want %v, %v", f.name, actor, got, err, want, wantErr)
		}
	}
	check(flag("a", map[string]string{"actors/User;1": "1"}), "User;1", true, nil)
	check(flag("b", map[string]string{"actors/User;1": "1"}), "User;2", false, nil)
	check(flag("c", map[string]string{"percentage_of_actors": "100"}), "User;2", true, nil)
	check(flag("d", map[string]string{"percentage_of_actors": "0"}), "User;2", false, nil)
	// Zlib.crc32("eUser;1") % 100_000 is 56_170 and "e2User;1"'s 63_963; Flipper compares them
	// with the scaled float.
	check(flag("e", map[string]string{"percentage_of_actors": "56.17"}), "User;1", false, nil)
	check(flag("e2", map[string]string{"percentage_of_actors": "63.9631"}), "User;1", true, nil)
	check(flag("g", map[string]string{"groups/admins": "1"}), "User;1", false, ErrUnevaluable)
	check(flag("h", map[string]string{"percentage_of_time": "50"}), "User;1", false, ErrUnevaluable)
	check(flag("i", map[string]string{"boolean": "true", "groups/admins": "1"}), "User;1", true, nil)
}
