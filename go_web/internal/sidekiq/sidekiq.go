// Package sidekiq pushes jobs the way Sidekiq 7.3.4's client does for the app's workers:
// same payload keys in the same order, same JSON bytes, same Redis commands.
package sidekiq

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// Options are a worker's sidekiq_options merged over config/initializers/sidekiq.rb's
// default_job_options. Retry is an int or a bool, as Ruby allows.
type Options struct {
	Class string
	Queue string
	Retry any
}

// Client pushes to the Sidekiq Redis (SIDEKIQ_REDIS_HOST).
type Client struct {
	Redis redis.Cmdable
	Now   func() time.Time
	// RedisVersion is the server's INFO redis_version, which PushUntilExecuted passes its
	// scripts as the gem does (they don't read it); LoadRedisVersion reads it.
	RedisVersion string
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Push is Worker.perform_async(*args). It returns the jid. A job that can't be serialized
// fails with an error wrapping ErrUnserializable; anything else is Redis's.
func (c *Client) Push(ctx context.Context, opts Options, args ...any) (string, error) {
	jid, payload, err := Payload(opts, args, c.now())
	if err != nil {
		return "", err
	}
	return jid, c.enqueue(ctx, opts.Queue, payload)
}

// PushIn is Worker.perform_in(interval, *args): a ZADD to "schedule" scored with the run-at
// time, or a plain push when that time is not in the future.
func (c *Client) PushIn(ctx context.Context, opts Options, interval time.Duration, args ...any) (string, error) {
	now := c.now()
	at := epochF(now) + interval.Seconds()
	jid, payload, err := payload(opts, args, now, true, interval > 0)
	if err != nil {
		return "", err
	}
	if interval <= 0 {
		return jid, c.enqueue(ctx, opts.Queue, payload)
	}
	return jid, c.Redis.ZAdd(ctx, "schedule", redis.Z{Score: at, Member: payload}).Err()
}

// enqueue is Client#atomic_push without a schedule, pipelined as raw_push sends it.
func (c *Client) enqueue(ctx context.Context, queue string, payload []byte) error {
	pipe := c.Redis.Pipeline()
	pipe.SAdd(ctx, "queues", queue)
	pipe.LPush(ctx, "queue:"+queue, payload)
	_, err := pipe.Exec(ctx)
	return err
}

// Payload builds perform_async's JSON. Key order follows normalize_item: default_job_options
// ({"retry", "queue", "backtrace"}) merged with the worker's options, then Setter's "args"
// and "class", then "jid" and "created_at", then atomic_push's "enqueued_at".
func Payload(opts Options, args []any, now time.Time) (string, []byte, error) {
	return payload(opts, args, now, false, false)
}

// payload also builds perform_in's, whose item puts "class" before "args" and whose
// scheduled push drops "enqueued_at".
func payload(opts Options, args []any, now time.Time, classFirst, scheduled bool) (string, []byte, error) {
	jid, job, _, err := normalizeItem(opts, args, now, classFirst, "")
	if err != nil {
		return "", nil, err
	}
	if !scheduled {
		job = append(job, Pair{"enqueued_at", epochF(now)})
	}
	out, err := Marshal(job)
	return jid, out, err
}

// normalizeItem is the item normalize_item leaves for the client middleware, with a worker's
// sidekiq-unique-jobs lock type when it has one, and the args it holds.
func normalizeItem(opts Options, args []any, now time.Time, classFirst bool, lock string) (string, Hash, []any, error) {
	if opts.Class == "" || opts.Queue == "" {
		return "", nil, nil, fmt.Errorf("sidekiq: job needs a class and a queue")
	}
	switch opts.Retry.(type) {
	case int, bool:
	default:
		return "", nil, nil, fmt.Errorf("sidekiq: retry must be an int or a bool")
	}
	if args == nil {
		args = []any{}
	}
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, nil, err
	}
	jid := hex.EncodeToString(raw)
	job := Hash{{"retry", opts.Retry}, {"queue", opts.Queue}, {"backtrace", true}}
	if lock != "" {
		job = append(job, Pair{"lock", lock})
	}
	if classFirst {
		job = append(job, Pair{"class", opts.Class}, Pair{"args", args})
	} else {
		job = append(job, Pair{"args", args}, Pair{"class", opts.Class})
	}
	return jid, append(job, Pair{"jid", jid}, Pair{"created_at", epochF(now)}), args, nil
}

// epochF is Time#to_f to the microsecond, as the payload's timestamps carry it.
func epochF(now time.Time) float64 { return float64(now.UnixMicro()) / 1e6 }
