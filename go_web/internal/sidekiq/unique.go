package sidekiq

import (
	"context"
	"crypto/md5"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// The scripts sidekiq-unique-jobs 8.0.10 loads, with their shared partial rendered in, byte
// for byte: their SHA1s are the ones already in the Sidekiq Redis.
var (
	//go:embed lua/queue.lua
	queueLua string
	//go:embed lua/lock.lua
	lockLua string
	//go:embed lua/unlock.lua
	unlockLua string

	queueScript  = uniqueScript{"queue", redis.NewScript(queueLua)}
	lockScript   = uniqueScript{"lock", redis.NewScript(lockLua)}
	unlockScript = uniqueScript{"unlock", redis.NewScript(unlockLua)}

	// releaseScript takes back a queued jid whose handoff failed, which unlock.lua leaves in
	// place (it yields to a non-empty QUEUED). 0 means lock.lua did run, so unlock.lua frees it.
	releaseScript = redis.NewScript(`
redis.pcall("LREM", KEYS[2], -1, ARGV[1])
redis.pcall("LREM", KEYS[3], -1, ARGV[1])
if redis.call("HEXISTS", KEYS[4], ARGV[1]) == 1 then return 0 end
if redis.call("GET", KEYS[1]) == ARGV[1] then redis.call("DEL", KEYS[1]) end
return 1`)
)

// uniqueScript is a script and the file name Script::Caller passes it.
type uniqueScript struct {
	name   string
	script *redis.Script
}

// sidekiq-unique-jobs' defaults, which config/initializers/sidekiq.rb leaves in place.
const (
	uniquePrefix    = "uniquejobs"
	uniqueChangelog = uniquePrefix + ":changelog"
	uniqueDigests   = uniquePrefix + ":digests"
	uniqueExpiring  = uniquePrefix + ":expiring_digests"
	maxHistory      = 1000

	lockUntilExecuted  = "until_executed"
	lockUntilExecuting = "until_executing"
)

// uniqueLock is Locksmith for one item: Key's keys, the job's jid and its lock type.
type uniqueLock struct {
	c                                    *Client
	jid, lockType                        string
	digest, queued, primed, locked, info string
	changelog, digests, expiringDigests  string
}

func (l *uniqueLock) keys() []string {
	return []string{l.digest, l.queued, l.primed, l.locked, l.info, l.changelog, l.digests, l.expiringDigests}
}

// run is call_script: Locksmith#argv for this item (pttl 0, limit 1, no "at") and Script::Caller's
// injected now_f, debug_lua (false is 0), max_history, file name and Redis version. A nil reply
// is "".
func (l *uniqueLock) run(ctx context.Context, s uniqueScript) (string, error) {
	argv := []any{l.jid, 0, l.lockType, 1, "", rubyNowF(l.c.now()), 0, maxHistory, s.name, l.c.RedisVersion}
	v, err := s.script.Run(ctx, l.c.Redis, l.keys(), argv...).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	reply, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("sidekiq: %s.lua replied %T", s.name, v)
	}
	return reply, nil
}

// PushUntilExecuted is perform_async for a worker with lock: :until_executed, through
// SidekiqUniqueJobs::Middleware::Client: the job is pushed only when its jid takes the lock.
// pushed is false when another job holds it, which the default NullStrategy swallows.
func (c *Client) PushUntilExecuted(ctx context.Context, opts Options, args ...any) (jid string, pushed bool, err error) {
	return c.pushUnique(ctx, lockUntilExecuted, opts, args)
}

// PushUntilExecuting is PushUntilExecuted for lock: :until_executing, which takes the lock
// the same way and only lets the server release it sooner.
func (c *Client) PushUntilExecuting(ctx context.Context, opts Options, args ...any) (jid string, pushed bool, err error) {
	return c.pushUnique(ctx, lockUntilExecuting, opts, args)
}

func (c *Client) pushUnique(ctx context.Context, lockType string, opts Options, args []any) (jid string, pushed bool, err error) {
	now := c.now()
	jid, job, args, err := normalizeItem(opts, args, now, false, lockType)
	if err != nil {
		return "", false, err
	}
	// Job.prepare, with no lock_args method: the lock args are the args.
	digestable, err := Marshal([]any{[]any{"class", opts.Class}, []any{"lock_args", args}, []any{"queue", opts.Queue}})
	if err != nil {
		return "", false, err
	}
	sum := md5.Sum(digestable)
	digest := uniquePrefix + ":" + hex.EncodeToString(sum[:])
	job = append(job, Pair{"lock_timeout", 0}, Pair{"lock_ttl", nil}, Pair{"lock_prefix", uniquePrefix},
		Pair{"lock_args", args}, Pair{"lock_digest", digest}, Pair{"enqueued_at", epochF(now)})
	payload, err := Marshal(job)
	if err != nil {
		return "", false, err
	}
	l := &uniqueLock{c: c, jid: jid, lockType: lockType, digest: digest, queued: digest + ":QUEUED", primed: digest + ":PRIMED",
		locked: digest + ":LOCKED", info: digest + ":INFO", changelog: uniqueChangelog, digests: uniqueDigests,
		expiringDigests: uniqueExpiring}
	locked, err := l.lock(ctx)
	if err != nil || !locked {
		return jid, false, err
	}
	if err := c.enqueue(ctx, opts.Queue, payload); err != nil {
		// reliable_push! would buffer this job; without that, free the lock so the next push
		// isn't swallowed by a job that never arrived.
		if _, unlockErr := l.run(ctx, unlockScript); unlockErr != nil {
			err = errors.Join(err, unlockErr)
		}
		return jid, false, err
	}
	return jid, true, nil
}

// release undoes a lock taken partway: a queued jid that never reached lock.lua, or a lock
// whose reply was lost.
func (l *uniqueLock) release(ctx context.Context) error {
	keys := []string{l.digest, l.queued, l.primed, l.locked}
	cleared, err := releaseScript.Run(ctx, l.c.Redis, keys, l.jid).Int()
	if err != nil || cleared == 1 {
		return err
	}
	_, err = l.run(ctx, unlockScript)
	return err
}

// lock is Locksmith#lock without a wait: queue.lua, the primed handoff, then lock.lua, each
// read the way lock! reads it.
func (l *uniqueLock) lock(ctx context.Context) (bool, error) {
	taken, err := l.c.Redis.HExists(ctx, l.locked, l.jid).Result()
	if err != nil || taken {
		return taken, err
	}
	queued, err := l.run(ctx, queueScript)
	if err != nil || !l.takes(queued) {
		return false, err
	}
	// Past queue.lua, a failed step would leave this jid queued for good: QUEUED has no TTL
	// and the reaper only reads the digests set lock.lua writes.
	primed, err := l.c.Redis.LMove(ctx, l.queued, l.primed, "RIGHT", "LEFT").Result()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	if err != nil {
		return false, errors.Join(err, l.release(ctx))
	}
	if !l.takes(primed) {
		return false, nil
	}
	lockedJID, err := l.run(ctx, lockScript)
	if err != nil {
		return false, errors.Join(err, l.release(ctx))
	}
	return lockedJID != "", nil
}

// takes is [job_id, "1"].include?(jid).
func (l *uniqueLock) takes(jid string) bool { return jid == l.jid || jid == "1" }

// LoadRedisVersion is SidekiqUniqueJobs.config.redis_version: INFO's redis_version.
func (c *Client) LoadRedisVersion(ctx context.Context) error {
	info, err := c.Redis.Info(ctx, "server").Result()
	if err != nil {
		return err
	}
	for _, line := range strings.Split(info, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "redis_version:"); ok {
			c.RedisVersion = v
			return nil
		}
	}
	return errors.New("sidekiq: INFO has no redis_version")
}

// rubyNowF is SidekiqUniqueJobs.now_f as redis-client sends it: Float#to_s.
func rubyNowF(now time.Time) string {
	s, _ := RubyFloat(float64(now.UnixNano()) / 1e9)
	return s
}
