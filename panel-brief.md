# Review brief — open the throttle window in the same write as its counter

Change class: shared-primitive hardening in a rate limiter. Two files.

Read:
- `app/controllers/concerns/throttling.rb` (the change)
- `spec/controllers/concerns/throttling_spec.rb` (the pin)
- `app/controllers/concerns/agent_request_throttling.rb` and
  `app/controllers/api/internal/ai_product_details_generations_controller.rb` — the only two call
  sites of `throttle!` in this repo.
- `app/services/redis_key.rb` for the key shapes.

The change: `throttle!` opened a caller's counter with `redis.incr(key)` followed by
`redis.expire(key, period) if count == 1`. It now opens it with one write:
`count = redis.set(key, 1, ex: period.to_i, nx: true) ? 1 : redis.incr(key)`.
A separate `EXPIRE` could be lost to a Redis failure, leaving a counter with no expiry — and an
expiry-less counter never resets, so that caller is eventually refused forever.

Check, in order:

1. **Window semantics preserved.** For a counter that does not exist, `SET NX EX period` yields
   count 1 and a TTL of `period`. For one that exists, `INCR` yields n+1 and leaves the TTL alone.
   Is the old fixed window reproduced exactly — same admission at `count == limit`, same refusal at
   `limit + 1`, same non-extension of the window on later requests? Name any input where the two
   versions disagree.
2. **The residual race.** If the key expires between `SET NX` returning nil and the following
   `INCR`, that `INCR` creates a counter with no TTL. Trace what happens next: does it self-heal
   through `ttl_to_retry_after`'s TTL `-1` branch, or can it lock a caller out? Say which, and
   whether the window is narrow enough to accept.
3. **Every `ttl_to_retry_after` answer still means what its comment says.** `0`, `-2` and `-1` are
   handled separately and the comment was updated. Is the updated claim about `-1` still true for
   both creation paths, and is `0`'s "do not reset the window" behaviour reachable and unchanged?
4. **Does the pin actually bite?** `spec/controllers/concerns/throttling_spec.rb` "opens a new
   counter and its window in one command" asserts `expect(redis).not_to receive(:expire)` and then
   a live TTL. Confirm it fails under the old two-command implementation and passes under the new
   one, and that it is not tautological or vacuous (e.g. does the request it makes actually reach
   `throttle!`?).
5. **Redis failure behaviour, stated honestly.** Under the old code a Redis outage raised out of
   `incr`. Under the new code it raises out of `set`. Is any caller relying on which command raised
   — a rescue keyed to `Redis::CannotConnectError` around a specific call, or a spec that stubs
   `incr` and not `set`? Check both call sites and their specs.
6. **Comments.** `AGENTS.md` requires ~3 lines, non-obvious why only, no incident narration. Judge
   the two comment edits against that.

Report only findings you verified in the code, with file:line and the input that triggers them. If
the diff is clean, say so plainly.
