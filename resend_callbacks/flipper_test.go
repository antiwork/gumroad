package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

type fakeHash struct {
	mu     sync.Mutex
	fields map[string]string
	err    error
	keys   []string
	block  chan struct{} // when set, reads wait for it to close
}

func (h *fakeHash) HGetAll(_ context.Context, key string) *redis.MapStringStringCmd {
	h.mu.Lock()
	h.keys = append(h.keys, key)
	fields, err, block := h.fields, h.err, h.block
	h.mu.Unlock()
	if block != nil {
		<-block
	}
	return redis.NewMapStringStringResult(fields, err)
}

func (h *fakeHash) reads() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.keys)
}

func newTestFlag(hash *fakeHash, now *time.Time) *flipperFlag {
	f := newFlipperFlag(hash, sendgridFlag)
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
		got, err := newTestFlag(hash, &now).active(context.Background())
		if err != nil || got != tc.want {
			t.Errorf("%s: active() = %v, %v; want %v", name, got, err, tc.want)
		}
		if len(hash.keys) != 1 || hash.keys[0] != "verify_sendgrid_webhook_signatures" {
			t.Errorf("%s: read %v", name, hash.keys)
		}
	}
}

func TestFlipperFlagCachesBrieflyAndFallsBackToItsLastRead(t *testing.T) {
	now := time.Unix(1792001956, 0)
	hash := &fakeHash{fields: map[string]string{"boolean": "true"}}
	flag := newTestFlag(hash, &now)
	ctx := context.Background()

	flag.active(ctx)
	now = now.Add(flagCacheTTL - time.Millisecond)
	if on, _ := flag.active(ctx); !on || len(hash.keys) != 1 {
		t.Fatalf("a fresh read went to Redis again: %v, %d reads", on, len(hash.keys))
	}

	now = now.Add(time.Second)
	hash.err = errors.New("i/o timeout")
	if on, err := flag.active(ctx); !on || err != nil || len(hash.keys) != 2 {
		t.Fatalf("a failed read must use the last good one: %v, %v, %d reads", on, err, len(hash.keys))
	}

	if on, _ := flag.active(ctx); !on || len(hash.keys) != 2 {
		t.Fatalf("Redis was retried within the backoff: %d reads", len(hash.keys))
	}

	now = now.Add(flagRetryBackoff)
	hash.err, hash.fields = nil, map[string]string{}
	if on, _ := flag.active(ctx); on || len(hash.keys) != 3 {
		t.Fatalf("a stale value outlived the next successful read: %d reads", len(hash.keys))
	}
}

func TestFlipperFlagRaisesWithoutAnyGoodRead(t *testing.T) {
	now := time.Unix(1792001956, 0)
	_, err := newTestFlag(&fakeHash{err: errors.New("connection refused")}, &now).active(context.Background())
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
			on, err := flag.active(ctx)
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
		flag.active(ctx)
		close(refreshed)
	}()
	waitFor(t, func() bool { return hash.reads() == 2 })
	for range 4 {
		if on, err := flag.active(ctx); !on || err != nil {
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
