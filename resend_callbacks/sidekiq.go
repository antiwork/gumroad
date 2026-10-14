package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"iter"
	"maps"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	jobClass = "HandleResendEventJob"
	// HandleResendEventJob's sidekiq_options; backtrace comes from Sidekiq.default_job_options.
	jobQueue   = "low"
	jobRetries = 5
)

// sidekiqJob is the payload Sidekiq::Client pushes, field for field.
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

type sidekiqQueue struct {
	client redis.UniversalClient
}

func (q *sidekiqQueue) enqueue(ctx context.Context, event map[string]any) error {
	payload, err := newJobPayload(event, time.Now())
	if err != nil {
		return err
	}
	// Sidekiq::Client#atomic_push without a schedule: register the queue, then push.
	pipe := q.client.Pipeline()
	pipe.SAdd(ctx, "queues", jobQueue)
	pipe.LPush(ctx, "queue:"+jobQueue, payload)
	_, err = pipe.Exec(ctx)
	return err
}

func newJobPayload(event map[string]any, now time.Time) ([]byte, error) {
	// The job object and its args array sit above the event.
	if err := serializableByRuby(event, 3); err != nil {
		return nil, err
	}
	jid := make([]byte, 12)
	if _, err := rand.Read(jid); err != nil {
		return nil, err
	}
	at := float64(now.UnixMicro()) / 1e6
	var payload bytes.Buffer
	encoder := json.NewEncoder(&payload)
	// Ruby's JSON.generate leaves <, > and & alone; match its bytes.
	encoder.SetEscapeHTML(false)
	err := encoder.Encode(sidekiqJob{
		Retry:      jobRetries,
		Queue:      jobQueue,
		Backtrace:  true,
		Args:       []any{event},
		Class:      jobClass,
		JID:        hex.EncodeToString(jid),
		CreatedAt:  at,
		EnqueuedAt: at,
	})
	return bytes.TrimSuffix(payload.Bytes(), []byte("\n")), err
}

// serializableByRuby fails where Sidekiq.dump_json (JSON.generate) raises on the same
// job: any container nested deeper than max_nesting, or a float Rails parsed to Infinity.
func serializableByRuby(value any, depth int) error {
	var items iter.Seq[any]
	switch v := value.(type) {
	case map[string]any:
		items = maps.Values(v)
	case []any:
		items = slices.Values(v)
	case json.Number:
		if strings.ContainsAny(string(v), ".eE") {
			if f, _ := v.Float64(); math.IsInf(f, 0) {
				return errors.New("number Ruby reads as Infinity")
			}
		}
		return nil
	default:
		return nil
	}
	if depth > maxNesting {
		return errors.New("job nested too deeply for JSON.generate")
	}
	for item := range items {
		if err := serializableByRuby(item, depth+1); err != nil {
			return err
		}
	}
	return nil
}
