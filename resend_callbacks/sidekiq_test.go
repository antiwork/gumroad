package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestJobPayloadMatchesWhatSidekiqClientPushes(t *testing.T) {
	now := time.Unix(1792001956, 315285000)
	payload, err := newJobPayload(resendJob, map[string]any{"from": `"Seller" <seller@example.com>`}, now)
	if err != nil {
		t.Fatal(err)
	}

	// Key order as Rails pushes it: retry, queue, backtrace, args, class, jid, created_at, enqueued_at.
	prefix := `{"retry":5,"queue":"low","backtrace":true,"args":[{"from":"\"Seller\" <seller@example.com>"}],"class":"HandleResendEventJob","jid":"`
	if !strings.HasPrefix(string(payload), prefix) {
		t.Fatalf("payload = %s", payload)
	}
	if !strings.HasSuffix(string(payload), `,"created_at":1792001956.315285,"enqueued_at":1792001956.315285}`) {
		t.Fatalf("payload = %s", payload)
	}

	var job sidekiqJob
	if err := json.Unmarshal(payload, &job); err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`\A[0-9a-f]{24}\z`).MatchString(job.JID) {
		t.Fatalf("jid = %q, want SecureRandom.hex(12)", job.JID)
	}
}

// Rails' perform_async raises from JSON.generate on these, so the request fails with a 500.
func TestJobPayloadRefusesWhatSidekiqCannotSerialize(t *testing.T) {
	nested := func(n int) any {
		var v any = []any{}
		for range n - 1 {
			v = []any{v}
		}
		return v
	}
	now := time.Unix(1792001956, 0)
	if _, err := newJobPayload(resendJob, map[string]any{"a": nested(97)}, now); err != nil {
		t.Errorf("a job 100 levels deep failed: %v", err)
	}
	if _, err := newJobPayload(resendJob, map[string]any{"a": nested(98)}, now); err == nil {
		t.Error("a job 101 levels deep was accepted")
	}
	if _, err := newJobPayload(resendJob, map[string]any{"n": json.Number("1e400")}, now); err == nil {
		t.Error("a number Ruby reads as Infinity was accepted")
	}
	if _, err := newJobPayload(resendJob, map[string]any{"n": json.Number("1e-400")}, now); err != nil {
		t.Errorf("an underflowing number failed: %v", err)
	}
}

func TestScheduledPayloadMatchesWhatPerformInPushes(t *testing.T) {
	now := time.Unix(1792001956, 315285000)
	payload, err := newScheduledPayload(mediaconvertJob, map[string]any{"Type": "Notification"}, now)
	if err != nil {
		t.Fatal(err)
	}
	// perform_in's item starts as {"class", "args"}, and atomic_push strips "at" and "enqueued_at".
	prefix := `{"retry":5,"queue":"default","backtrace":true,"class":"HandleSnsMediaconvertEventWorker","args":[{"Type":"Notification"}],"jid":"`
	if !strings.HasPrefix(string(payload), prefix) || !strings.HasSuffix(string(payload), `,"created_at":1792001956.315285}`) {
		t.Fatalf("payload = %s", payload)
	}
}

// fakeRedis answers just enough RESP for go-redis to connect, and records each command.
type fakeRedis struct {
	addr     string
	mu       sync.Mutex
	commands [][]string
}

func startFakeRedis(t *testing.T) *fakeRedis {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r := &fakeRedis{addr: ln.Addr().String()}
	var wg sync.WaitGroup
	t.Cleanup(func() { ln.Close(); wg.Wait() })
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer conn.Close()
				r.serve(bufio.NewReader(conn), conn)
			}()
		}
	}()
	return r
}

func (r *fakeRedis) serve(in *bufio.Reader, out io.Writer) {
	for {
		line, err := in.ReadString('\n')
		if err != nil || !strings.HasPrefix(line, "*") {
			return
		}
		n, _ := strconv.Atoi(strings.TrimSpace(line[1:]))
		command := make([]string, n)
		for i := range command {
			header, err := in.ReadString('\n')
			if err != nil {
				return
			}
			size, _ := strconv.Atoi(strings.TrimSpace(header[1:]))
			data := make([]byte, size+2)
			if _, err := io.ReadFull(in, data); err != nil {
				return
			}
			command[i] = string(data[:size])
		}
		r.mu.Lock()
		r.commands = append(r.commands, command)
		r.mu.Unlock()
		switch strings.ToUpper(command[0]) {
		case "HELLO":
			io.WriteString(out, "-ERR unknown command 'HELLO'\r\n")
		case "SADD", "LPUSH", "ZADD":
			io.WriteString(out, ":1\r\n")
		default:
			io.WriteString(out, "+OK\r\n")
		}
	}
}

func (r *fakeRedis) jobCommands() [][]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var jobs [][]string
	for _, c := range r.commands {
		if name := strings.ToUpper(c[0]); name == "SADD" || name == "LPUSH" || name == "ZADD" {
			jobs = append(jobs, c)
		}
	}
	return jobs
}

func TestEnqueueSendsTheCommandsSidekiqClientSends(t *testing.T) {
	r := startFakeRedis(t)
	client := redis.NewClient(&redis.Options{Addr: r.addr})
	defer client.Close()
	q := &sidekiqQueue{client: client}
	ctx := context.Background()

	if err := q.enqueue(ctx, stripeJob, map[string]any{"id": "evt_1"}, 0); err != nil {
		t.Fatal(err)
	}
	before := float64(time.Now().UnixMicro()) / 1e6
	if err := q.enqueue(ctx, mediaconvertJob, map[string]any{"Type": "Notification"}, mediaconvertDelay); err != nil {
		t.Fatal(err)
	}

	commands := r.jobCommands()
	if len(commands) != 3 {
		t.Fatalf("commands = %q", commands)
	}
	if got := strings.Join(commands[0], " "); got != "sadd queues default" {
		t.Errorf("first command = %q", got)
	}
	if commands[1][0] != "lpush" || commands[1][1] != "queue:default" || !strings.HasPrefix(commands[1][2], `{"retry":10,"queue":"default","backtrace":true,"args":[{"id":"evt_1"}],"class":"HandleStripeEventWorker",`) {
		t.Errorf("push = %q", commands[1])
	}

	// No SADD: a scheduled job only joins its queue when the scheduler moves it.
	zadd := commands[2]
	if zadd[0] != "zadd" || zadd[1] != "schedule" || len(zadd) != 4 {
		t.Fatalf("schedule = %q", zadd)
	}
	var job scheduledJob
	if err := json.Unmarshal([]byte(zadd[3]), &job); err != nil {
		t.Fatal(err)
	}
	score, err := strconv.ParseFloat(zadd[2], 64)
	if err != nil || score < before+5 || score-job.CreatedAt < 4.999 || score-job.CreatedAt > 5.001 {
		t.Errorf("score %s for created_at %f, want created_at + 5", zadd[2], job.CreatedAt)
	}
	if strings.Contains(zadd[3], "enqueued_at") || strings.Contains(zadd[3], `"at"`) {
		t.Errorf("scheduled payload = %s", zadd[3])
	}
}

func TestEnqueueRefusesWhatJSONGenerateRaisesOn(t *testing.T) {
	client := redis.NewClient(&redis.Options{Addr: "127.0.0.1:0"})
	defer client.Close()
	q := &sidekiqQueue{client: client}
	err := q.enqueue(context.Background(), awsConfigJob, map[string]any{"n": json.Number("1e400")}, 0)
	if !errors.Is(err, errUnserializable) {
		t.Fatalf("enqueue() = %v, want errUnserializable before any Redis call", err)
	}
}
