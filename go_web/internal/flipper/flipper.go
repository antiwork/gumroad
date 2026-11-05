// Package flipper reads Flipper flags as Feature.active? does without an actor.
package flipper

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"math/rand/v2"
	"strings"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	flagCacheTTL = 5 * time.Second
	// After a failed read the last value is used this long before Redis is tried again.
	flagRetryBackoff = time.Second
	// redis-client's default connect, read and write timeouts, which $redis uses.
	flagTimeout = time.Second
)

// HashReader is the Redis call a flag makes.
type HashReader interface {
	HGetAll(ctx context.Context, key string) *redis.MapStringStringCmd
}

// Flag reads one flag as Feature.active?(name) does without an actor, through
// flipper-redis 1.3.0 (a hash at the flag's own name) and RedisFailOpen: a failed read
// falls back to this process's last successful one, or raises when there was none.
type Flag struct {
	client HashReader
	name   string
	now    func() time.Time
	random func() float64

	state   atomic.Pointer[flagState] // nil until a read succeeds
	reading atomic.Pointer[flagRead]  // the one read in flight
}

// flagState holds the gates that can open without an actor, in Flipper's order. An
// expression gate can't be evaluated here, so a set one makes the flag unknown.
type flagState struct {
	boolean          bool
	expression       bool
	percentageOfTime float64
	readAt, failedAt time.Time
}

// ErrUnevaluable is a flag whose expression gate only Flipper can evaluate.
var ErrUnevaluable = errors.New("an expression gate is set, which only Flipper can evaluate")

type flagRead struct {
	done chan struct{}
	err  error
}

// New is the flag name, read through client.
func New(client HashReader, name string) *Flag {
	return &Flag{client: client, name: name, now: time.Now, random: rand.Float64}
}

// Active is Feature.active?(name).
func (f *Flag) Active(ctx context.Context) (bool, error) {
	for {
		state := f.state.Load()
		if now := f.now(); state != nil && (now.Sub(state.readAt) < flagCacheTTL || now.Sub(state.failedAt) < flagRetryBackoff) {
			return f.open(state)
		}
		read := &flagRead{done: make(chan struct{})}
		if f.reading.CompareAndSwap(nil, read) {
			// Detached, so one reader leaving doesn't fail the others waiting; flagTimeout bounds it.
			read.err = f.refresh(context.WithoutCancel(ctx), state)
			f.reading.Store(nil)
			close(read.done)
		} else if state != nil {
			return f.open(state)
		} else if read = f.reading.Load(); read == nil {
			continue
		}
		select {
		case <-read.done:
		case <-ctx.Done():
			return false, ctx.Err()
		}
		if state = f.state.Load(); state != nil {
			return f.open(state)
		}
		return false, read.err
	}
}

func (f *Flag) refresh(ctx context.Context, last *flagState) error {
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
	expression, hasExpression := gates["expression"]
	f.state.Store(&flagState{
		boolean:          b == "true" || b == "1",
		expression:       hasExpression && expressionSet(expression),
		percentageOfTime: flipperNumber(gates["percentage_of_time"]),
		readAt:           f.now(),
	})
	return nil
}

func (f *Flag) open(state *flagState) (bool, error) {
	switch {
	case state.boolean:
		return true, nil
	case state.expression:
		return false, ErrUnevaluable
	}
	return f.random() < state.percentageOfTime/100, nil
}

// expressionSet is the Expression gate's `!data.nil? && !data.empty?` on the stored JSON.
// What Ruby would raise on also counts, since it can't be read as off either.
func expressionSet(raw string) bool {
	var data any
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return true
	}
	switch v := data.(type) {
	case nil:
		return false
	case map[string]any:
		return len(v) > 0
	case []any:
		return len(v) > 0
	case string:
		return v != ""
	}
	return true
}

// flipperNumber mirrors Flipper::Typecast.to_number on a stored string.
func flipperNumber(s string) float64 {
	if strings.Contains(s, ".") {
		f, _ := rails.StringToF(s)
		return f
	}
	n, ok := rails.StringToI(s)
	if !ok {
		// A Bignum percentage opens the gate whenever it's positive, whatever follows its digits.
		if strings.HasPrefix(strings.TrimLeft(s, rails.RubySpace), "-") {
			return math.Inf(-1)
		}
		return math.Inf(1)
	}
	return float64(n)
}
