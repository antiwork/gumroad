package main

import (
	"context"
	"math/rand/v2"
	"strings"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	flagCacheTTL = 5 * time.Second
	// After a failed read the last value is used this long before Redis is tried again.
	flagRetryBackoff = time.Second
	// redis-client's default connect, read and write timeouts, which $redis uses.
	flagTimeout = time.Second
)

type featureFlag interface {
	active(ctx context.Context) (bool, error)
}

type hashReader interface {
	HGetAll(ctx context.Context, key string) *redis.MapStringStringCmd
}

// flipperFlag reads one flag as Feature.active?(name) does without an actor, through
// flipper-redis 1.3.0 (a hash at the flag's own name) and RedisFailOpen: a failed read
// falls back to this process's last successful one, or raises when there was none.
type flipperFlag struct {
	client hashReader
	name   string
	now    func() time.Time
	random func() float64

	state   atomic.Pointer[flagState] // nil until a read succeeds
	reading atomic.Pointer[flagRead]  // the one read in flight
}

// flagState holds the gates that can open without an actor. An expression gate isn't
// evaluated and stays closed.
type flagState struct {
	boolean          bool
	percentageOfTime float64
	readAt, failedAt time.Time
}

type flagRead struct {
	done chan struct{}
	err  error
}

func newFlipperFlag(client hashReader, name string) *flipperFlag {
	return &flipperFlag{client: client, name: name, now: time.Now, random: rand.Float64}
}

func (f *flipperFlag) active(ctx context.Context) (bool, error) {
	for {
		state := f.state.Load()
		if now := f.now(); state != nil && (now.Sub(state.readAt) < flagCacheTTL || now.Sub(state.failedAt) < flagRetryBackoff) {
			return f.open(state), nil
		}
		read := &flagRead{done: make(chan struct{})}
		if f.reading.CompareAndSwap(nil, read) {
			read.err = f.refresh(ctx, state)
			f.reading.Store(nil)
			close(read.done)
		} else if state != nil {
			return f.open(state), nil
		} else if read = f.reading.Load(); read == nil {
			continue
		}
		select {
		case <-read.done:
		case <-ctx.Done():
			return false, ctx.Err()
		}
		if state = f.state.Load(); state != nil {
			return f.open(state), nil
		}
		return false, read.err
	}
}

func (f *flipperFlag) refresh(ctx context.Context, last *flagState) error {
	ctx, cancel := context.WithTimeout(ctx, flagTimeout)
	defer cancel()
	gates, err := f.client.HGetAll(ctx, f.name).Result()
	if err != nil {
		if last != nil {
			failed := *last
			failed.failedAt = f.now()
			f.state.Store(&failed)
		}
		return err
	}
	b := gates["boolean"]
	f.state.Store(&flagState{
		boolean:          b == "true" || b == "1",
		percentageOfTime: flipperNumber(gates["percentage_of_time"]),
		readAt:           f.now(),
	})
	return nil
}

func (f *flipperFlag) open(state *flagState) bool {
	return state.boolean || f.random() < state.percentageOfTime/100
}

// flipperNumber mirrors Flipper::Typecast.to_number on a stored string.
func flipperNumber(s string) float64 {
	if strings.Contains(s, ".") {
		return rubyToF(s)
	}
	return float64(rubyToI(s))
}
