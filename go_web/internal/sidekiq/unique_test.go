package sidekiq

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

// The gem's rendered scripts, whose SHA1s production's Sidekiq Redis has loaded.
func TestTheUniqueJobsScriptsAreTheGems(t *testing.T) {
	for name, c := range map[string]struct{ src, want string }{
		"queue":  {queueLua, "abf4915d03d5930a3350746f4ee07678cf4f1fd5"},
		"lock":   {lockLua, "023cd507fb3ca2483e369693af4a83e0a49f7e2a"},
		"unlock": {unlockLua, "69cc8e36ce17205db6fd0267c39a531efb722829"},
	} {
		if sum := sha1.Sum([]byte(c.src)); hex.EncodeToString(sum[:]) != c.want {
			t.Errorf("%s.lua is %x", name, sum)
		}
	}
}

func TestPushUntilExecutedPushesOnlyTheLockHolder(t *testing.T) {
	m := miniredis.RunT(t)
	c := &Client{Redis: redis.NewClient(&redis.Options{Addr: m.Addr()}), RedisVersion: "7.2.4",
		Now: func() time.Time { return time.Unix(1762430000, 250_000_000) }}
	opts := Options{Class: "WarmSellerReputationSummaryJob", Queue: "low", Retry: 1}
	ctx := context.Background()
	jid, pushed, err := c.PushUntilExecuted(ctx, opts, 123)
	if err != nil || !pushed {
		t.Fatalf("first push: %v %v", pushed, err)
	}
	// As production's client middleware leaves the item, after atomic_push's enqueued_at.
	const digest = "uniquejobs:54836a5574f6fc94db07c5b73bcdea7f"
	want := `{"retry":1,"queue":"low","backtrace":true,"lock":"until_executed","args":[123],"class":"WarmSellerReputationSummaryJob",` +
		`"jid":"` + jid + `","created_at":1762430000.25,"lock_timeout":0,"lock_ttl":null,"lock_prefix":"uniquejobs","lock_args":[123],` +
		`"lock_digest":"` + digest + `","enqueued_at":1762430000.25}`
	if got, _ := m.List("queue:low"); len(got) != 1 || got[0] != want {
		t.Errorf("queue %v\nwant %s", got, want)
	}
	if !m.Exists(digest+":LOCKED") || m.HGet(digest+":LOCKED", jid) == "" {
		t.Errorf("%s is not locked by %s", digest, jid)
	}
	if got, _ := m.Get(digest); got != jid {
		t.Errorf("digest holds %q", got)
	}
	// Another push while the job waits takes no lock and pushes nothing.
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 123); err != nil || pushed {
		t.Errorf("second push: %v %v", pushed, err)
	}
	if got, _ := m.List("queue:low"); len(got) != 1 {
		t.Errorf("queue has %d jobs", len(got))
	}
	// queue.lua logs the refusal as Rails' push would.
	entries, _ := m.ZMembers("uniquejobs:changelog")
	messages := map[string]int{}
	for _, e := range entries {
		var entry struct{ Message string }
		json.Unmarshal([]byte(e), &entry)
		messages[entry.Message]++
	}
	if messages["Queued"] != 1 || messages["Locked"] != 1 || messages["Limit exceeded"] != 1 {
		t.Errorf("changelog %v", messages)
	}
	// A different seller is its own lock.
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 124); err != nil || !pushed {
		t.Errorf("another seller: %v %v", pushed, err)
	}
}

// The server reads the lock type off the item, so only the payload differs from until_executed.
func TestPushUntilExecutingNamesItsLock(t *testing.T) {
	m := miniredis.RunT(t)
	c := &Client{Redis: redis.NewClient(&redis.Options{Addr: m.Addr()}), RedisVersion: "7.2.4",
		Now: func() time.Time { return time.Unix(1762430000, 250_000_000) }}
	opts := Options{Class: "GenerateAvatarVariantJob", Queue: "low", Retry: 3}
	ctx := context.Background()
	jid, pushed, err := c.PushUntilExecuting(ctx, opts, 123)
	if err != nil || !pushed {
		t.Fatalf("first push: %v %v", pushed, err)
	}
	const digest = "uniquejobs:6a6f0d59833859476105772723cf5b8e"
	want := `{"retry":3,"queue":"low","backtrace":true,"lock":"until_executing","args":[123],"class":"GenerateAvatarVariantJob",` +
		`"jid":"` + jid + `","created_at":1762430000.25,"lock_timeout":0,"lock_ttl":null,"lock_prefix":"uniquejobs","lock_args":[123],` +
		`"lock_digest":"` + digest + `","enqueued_at":1762430000.25}`
	if got, _ := m.List("queue:low"); len(got) != 1 || got[0] != want {
		t.Errorf("queue %v\nwant %s", got, want)
	}
	if _, pushed, err := c.PushUntilExecuting(ctx, opts, 123); err != nil || pushed {
		t.Errorf("second push: %v %v", pushed, err)
	}
}

func TestAFailedPushFreesItsLock(t *testing.T) {
	m := miniredis.RunT(t)
	c := &Client{Redis: redis.NewClient(&redis.Options{Addr: m.Addr()}), RedisVersion: "7.2.4"}
	opts := Options{Class: "WarmSellerReputationSummaryJob", Queue: "low", Retry: 1}
	ctx := context.Background()
	// LPUSH onto a string fails after the lock is taken.
	m.Set("queue:low", "not a list")
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 123); err == nil || pushed {
		t.Fatalf("push onto a string: %v %v", pushed, err)
	}
	const digest = "uniquejobs:54836a5574f6fc94db07c5b73bcdea7f"
	if m.Exists(digest) || m.Exists(digest+":LOCKED") {
		t.Fatalf("the lock outlived the failed push: %v", m.Keys())
	}
	// So the next push takes it and arrives.
	m.Del("queue:low")
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 123); err != nil || !pushed {
		t.Errorf("next push: %v %v", pushed, err)
	}
}

func TestAFailedHandoffReleasesTheQueuedJID(t *testing.T) {
	m := miniredis.RunT(t)
	c := &Client{Redis: redis.NewClient(&redis.Options{Addr: m.Addr()}), RedisVersion: "7.2.4"}
	opts := Options{Class: "WarmSellerReputationSummaryJob", Queue: "low", Retry: 1}
	ctx := context.Background()
	const digest = "uniquejobs:54836a5574f6fc94db07c5b73bcdea7f"
	// LMOVE onto a string fails after queue.lua queued the jid.
	m.Set(digest+":PRIMED", "not a list")
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 123); err == nil || pushed {
		t.Fatalf("failed handoff: %v %v", pushed, err)
	}
	if m.Exists(digest) || m.Exists(digest+":QUEUED") {
		t.Fatalf("the queued jid outlived the failure: %v", m.Keys())
	}
	m.Del(digest + ":PRIMED")
	if _, pushed, err := c.PushUntilExecuted(ctx, opts, 123); err != nil || !pushed {
		t.Errorf("next push: %v %v", pushed, err)
	}
}
