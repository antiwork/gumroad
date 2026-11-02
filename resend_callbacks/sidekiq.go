package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// A job class's sidekiq_options; backtrace comes from Sidekiq.default_job_options.
type jobSpec struct {
	class, queue string
	retry        int
	// The queue's list key, and its name boxed once for SADD.
	queueKey    string
	queueMember any
}

func newJobSpec(class, queue string, retry int) jobSpec {
	return jobSpec{class: class, queue: queue, retry: retry, queueKey: "queue:" + queue, queueMember: queue}
}

var (
	resendJob       = newJobSpec("HandleResendEventJob", "low", 5)
	stripeJob       = newJobSpec("HandleStripeEventWorker", "default", 10)
	sendgridJob     = newJobSpec("HandleSendgridEventJob", "low", 5)
	mediaconvertJob = newJobSpec("HandleSnsMediaconvertEventWorker", "default", 5)
	awsConfigJob    = newJobSpec("HandleSnsAwsConfigEventWorker", "low", 5)
)

// errUnserializable is a job Sidekiq.dump_json raises on. Rails answers that with a
// 500; a Redis failure gets REDIS_TRANSPORT_ERRORS' 503.
var errUnserializable = errors.New("job is not serializable by JSON.generate")

// sidekiqJob is the payload Sidekiq::Client pushes for perform_async, field for field.
type sidekiqJob struct {
	Retry      int     `json:"retry"`
	Queue      string  `json:"queue"`
	Backtrace  bool    `json:"backtrace"`
	Args       []any   `json:"args"`
	Class      string  `json:"class"`
	JID        string  `json:"jid"`
	CreatedAt  float64 `json:"created_at"`
	EnqueuedAt float64 `json:"enqueued_at"`
}

// scheduledJob is perform_in's payload: its item starts as {"class", "args"}, and
// atomic_push strips "at" into the sorted-set score.
type scheduledJob struct {
	Retry     int     `json:"retry"`
	Queue     string  `json:"queue"`
	Backtrace bool    `json:"backtrace"`
	Class     string  `json:"class"`
	Args      []any   `json:"args"`
	JID       string  `json:"jid"`
	CreatedAt float64 `json:"created_at"`
}

type sidekiqQueue struct {
	client redis.UniversalClient
}

func (q *sidekiqQueue) enqueue(ctx context.Context, job jobSpec, arg any, delay time.Duration) error {
	now := time.Now()
	if delay > 0 {
		payload, err := newScheduledPayload(job, arg, now)
		if err != nil {
			return err
		}
		at := unixSeconds(now) + delay.Seconds()
		return q.client.ZAdd(ctx, "schedule", redis.Z{Score: at, Member: payload}).Err()
	}
	payload, err := newJobPayload(job, arg, now)
	if err != nil {
		return err
	}
	// Sidekiq::Client#atomic_push without a schedule: register the queue, then push.
	pipe := q.client.Pipeline()
	pipe.SAdd(ctx, "queues", job.queueMember)
	pipe.LPush(ctx, job.queueKey, payload)
	_, err = pipe.Exec(ctx)
	return err
}

func newJobPayload(job jobSpec, arg any, now time.Time) ([]byte, error) {
	if err := checkSerializable(arg); err != nil {
		return nil, err
	}
	jid, err := newJID()
	if err != nil {
		return nil, err
	}
	at := unixSeconds(now)
	return marshalLikeRuby(sidekiqJob{
		Retry:      job.retry,
		Queue:      job.queue,
		Backtrace:  true,
		Args:       []any{arg},
		Class:      job.class,
		JID:        jid,
		CreatedAt:  at,
		EnqueuedAt: at,
	})
}

func newScheduledPayload(job jobSpec, arg any, now time.Time) ([]byte, error) {
	if err := checkSerializable(arg); err != nil {
		return nil, err
	}
	jid, err := newJID()
	if err != nil {
		return nil, err
	}
	return marshalLikeRuby(scheduledJob{
		Retry:     job.retry,
		Queue:     job.queue,
		Backtrace: true,
		Class:     job.class,
		Args:      []any{arg},
		JID:       jid,
		CreatedAt: unixSeconds(now),
	})
}

// checkSerializable starts at depth 3: the job object and its args array sit above the argument.
func checkSerializable(arg any) error {
	if err := serializableByRuby(arg, 3); err != nil {
		return fmt.Errorf("%w: %w", errUnserializable, err)
	}
	return nil
}

// newJID makes SecureRandom.hex(12).
func newJID() (string, error) {
	jid := make([]byte, 12)
	if _, err := rand.Read(jid); err != nil {
		return "", err
	}
	return hex.EncodeToString(jid), nil
}

func unixSeconds(t time.Time) float64 {
	return float64(t.UnixMicro()) / 1e6
}

func marshalLikeRuby(v any) ([]byte, error) {
	var payload bytes.Buffer
	encoder := json.NewEncoder(&payload)
	// Ruby's JSON.generate leaves <, > and & alone; match its bytes.
	encoder.SetEscapeHTML(false)
	err := encoder.Encode(v)
	return bytes.TrimSuffix(payload.Bytes(), []byte("\n")), err
}

// serializableByRuby fails where Sidekiq.dump_json (JSON.generate) raises on the same
// job: any container nested deeper than max_nesting, or a float Ruby parsed to Infinity.
func serializableByRuby(value any, depth int) error {
	switch v := value.(type) {
	case map[string]any:
		if depth > maxNesting {
			return errTooDeepToGenerate
		}
		for _, item := range v {
			if err := serializableByRuby(item, depth+1); err != nil {
				return err
			}
		}
	case []any:
		if depth > maxNesting {
			return errTooDeepToGenerate
		}
		for _, item := range v {
			if err := serializableByRuby(item, depth+1); err != nil {
				return err
			}
		}
	case json.Number:
		if rubyInfinity(v) {
			return errors.New("number Ruby reads as Infinity")
		}
	}
	return nil
}

var errTooDeepToGenerate = errors.New("job nested too deeply for JSON.generate")

// rubyInfinity reports a JSON number Ruby parses to a Float that overflows; integers
// become Bignums instead.
func rubyInfinity(n json.Number) bool {
	if !strings.ContainsAny(string(n), ".eE") {
		return false
	}
	f, _ := n.Float64()
	return math.IsInf(f, 0)
}
