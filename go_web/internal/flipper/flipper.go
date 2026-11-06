// Package flipper reads Flipper flags as Feature.active? does, with or without an actor.
package flipper

import (
	"context"
	"encoding/json"
	"errors"
	"hash/crc32"
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

// Flag reads one flag as Feature.active? does, through flipper-redis 1.3.0 (a hash at the flag's own name) and RedisFailOpen: a failed read
// falls back to this process's last successful one, or raises when there was none.
type Flag struct {
	client HashReader
	name   string
	now    func() time.Time
	random func() float64

	state   atomic.Pointer[flagState] // nil until a read succeeds
	reading atomic.Pointer[flagRead]  // the one read in flight
}

// flagState holds the flag's gates. An expression gate can't be evaluated here, so a set
// one makes the flag unknown.
type flagState struct {
	boolean          bool
	expression       bool
	percentageOfTime float64
	// The actor gates: enabled actor ids, whether any group is enabled (a group's block is
	// Ruby), and the percentage of actors.
	actors             map[string]bool
	groups             bool
	percentageOfActors float64
	readAt, failedAt   time.Time
}

// ErrUnevaluable is a flag with a gate only Flipper can evaluate: an expression, or for an
// actor an enabled group or a partial percentage of time.
var ErrUnevaluable = errors.New("flipper: a gate only Flipper can evaluate is set")

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
	return f.active(ctx, "")
}

// ActiveFor is Feature.active?(name, actor) for the actor's flipper_id, such as "User;1".
// A partial percentage of time is random in Rails, so a page that reads it can't be
// matched; it, and any enabled group, is ErrUnevaluable when no earlier gate opens.
func (f *Flag) ActiveFor(ctx context.Context, flipperID string) (bool, error) {
	return f.active(ctx, flipperID)
}

func (f *Flag) active(ctx context.Context, actor string) (bool, error) {
	for {
		state := f.state.Load()
		if now := f.now(); state != nil && (now.Sub(state.readAt) < flagCacheTTL || now.Sub(state.failedAt) < flagRetryBackoff) {
			return f.open(state, actor)
		}
		read := &flagRead{done: make(chan struct{})}
		if f.reading.CompareAndSwap(nil, read) {
			// Detached, so one reader leaving doesn't fail the others waiting; flagTimeout bounds it.
			read.err = f.refresh(context.WithoutCancel(ctx), state)
			f.reading.Store(nil)
			close(read.done)
		} else if state != nil {
			return f.open(state, actor)
		} else if read = f.reading.Load(); read == nil {
			continue
		}
		select {
		case <-read.done:
		case <-ctx.Done():
			return false, ctx.Err()
		}
		if state = f.state.Load(); state != nil {
			return f.open(state, actor)
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
	state := &flagState{
		boolean:            b == "true" || b == "1",
		expression:         hasExpression && expressionSet(expression),
		percentageOfTime:   flipperNumber(gates["percentage_of_time"]),
		percentageOfActors: flipperNumber(gates["percentage_of_actors"]),
		actors:             map[string]bool{},
		readAt:             f.now(),
	}
	// flipper-redis keeps a set gate's members as "<gate>/<value>" fields.
	for field := range gates {
		if id, ok := strings.CutPrefix(field, "actors/"); ok {
			state.actors[id] = true
		} else if strings.HasPrefix(field, "groups/") {
			state.groups = true
		}
	}
	f.state.Store(state)
	return nil
}

// open runs Flipper's gates in order: boolean, expression, actor, percentage of actors,
// percentage of time, group.
func (f *Flag) open(state *flagState, actor string) (bool, error) {
	switch {
	case state.boolean:
		return true, nil
	case state.expression:
		return false, ErrUnevaluable
	}
	if actor == "" {
		return f.random() < state.percentageOfTime/100, nil
	}
	if state.actors[actor] {
		return true, nil
	}
	// PercentageOfActors: crc32 of the feature name and the actor's id, scaled by 1,000.
	if float64(crc32.ChecksumIEEE([]byte(f.name+actor))%100_000) < state.percentageOfActors*1000 {
		return true, nil
	}
	switch {
	case state.percentageOfTime >= 100:
		return true, nil
	case state.percentageOfTime > 0, state.groups:
		return false, ErrUnevaluable
	}
	return false, nil
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
