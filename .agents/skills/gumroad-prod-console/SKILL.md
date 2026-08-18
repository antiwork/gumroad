---
name: gumroad-prod-console
description: >
  Execute read-only Ruby/Rails commands against Gumroad's production database for debugging
  and investigation. Use when the user needs to debug production issues, look up data,
  investigate user reports, check records, or query production state. Triggers on: "check in
  prod", "debug this in prod", "look up user/purchase/product in production", "production
  console", "investigate in prod", "query production", "what's happening in prod", "look up
  a user by email", "who bought this product", "why is this user blocked", "find this
  sale/purchase", "how many X does Y have", or any request to examine live Gumroad data —
  even when the user doesn't say "prod" explicitly.
---

# Gumroad production console

Read-only Rails runner against the production read replica via bastion SSH.

## Execution

```bash
.claude/skills/gumroad-prod-console/scripts/prod_query.sh 'puts User.count'
.claude/skills/gumroad-prod-console/scripts/prod_query.sh /tmp/query.rb
echo 'puts User.count' | .claude/skills/gumroad-prod-console/scripts/prod_query.sh
```

Multi-line queries: write a temp `.rb` file, pass its path. Bash tool timeout is ~120s — wrap slow queries in `WithMaxExecutionTime.timeout_queries(seconds: 30) { ... }`. Queries run against the read replica (`DATABASE_WORKER_REPLICA1_HOST` by default).

Follow-up queries are cheap — start scoped (one record, one field), then drill in as the investigation clarifies. Avoid the urge to return everything in a single large query.

Warm hops: `prod_query.sh` multiplexes SSH to the bastion (`ControlPersist`) and reuses the last-good instance IP for 10 minutes (`PROD_IP_CACHE_TTL`). A second query should skip EC2 discovery. Pin with `PROD_INSTANCE_IP` to skip it entirely. Tracked in gumroad-private#2197.

## Safety

- **Read-only.** Never write, update, or delete.
- Always `.limit()` / `.first()` / `.take()` — never unbounded result sets.
- Prefer `.pluck(:col, :col)` over loading full AR objects.
- Mask PII in output (truncate emails, addresses, payment details).
- `.explain` before querying large tables without indexed conditions.
- Emit structured output (JSON for complex, `.inspect` for simple) so results are parseable.

## Gumroad-specific gotchas

### External IDs, not primary keys

Admin URLs and public IDs use **external IDs** (`ExternalId` module — Base64 strings like `aBcDeFgHiJkLmNoPqRsTuQ==`), not integer PKs.

```ruby
Purchase.find_by_external_id("aBcDeFgHiJkLmNoPqRsTuQ==")  # correct
Purchase.find("aBcDeFgHiJkLmNoPqRsTuQ==")                  # WRONG — treats it as a PK, silently returns the wrong record
```

### Model naming

| Model | Note |
|---|---|
| `Link` | The product model (legacy name). `find_by(unique_permalink:)` for permalinks; `alive` scope for non-deleted. |
| `Installment` | Subscriptions/recurring (not ActiveRecord's sense of "installment"). `where(link_id:, alive: true)`. |
| `Comment` | Admin notes on records. `content` field, **not** `body`. |
| `MerchantAccount` | Processor-specific — users can have multiple. `where(user_id:, charge_processor_id:)`. |
| `Purchase` | `successful` scope for completed sales. `where(email:)`, `where(link_id:)`. |

`User`, `Balance`, `Dispute`, `Follower`, `CustomDomain` behave as names suggest.

### Sidekiq queues

`critical` (12k limit — payouts, webhooks, receipts) → `default` (300k — general) → `long` (PDF stamping etc.) → `low` (expiry). Queue limits at `app/controllers/healthcheck_controller.rb:28`; worker ordering at `docker/web/sidekiq_worker.sh`.

### DevTools (Gumroad-specific helpers)

See `lib/utilities/dev_tools.rb`:

- `DevTools.reindex_all_for_user(user_id)` — reindex ES data
- `DevTools.reimport_follower_events_for_user!(user)` — reimport follower analytics

For Gumroad-specific scopes and associations (`alive`, `successful`, `unpaid_balance_cents`, `payments`, `products`, Flipper checks, Sidekiq introspection), see [references/common-queries.md](references/common-queries.md).

### Stale bastion host keys look like unhealthy instances

EC2 recycles private IPs, so the **bastion's** `known_hosts` accumulates stale keys and refuses the onward hop with `REMOTE HOST IDENTIFICATION HAS CHANGED` / `Offending ECDSA key`. From outside this is easy to mistake for a hung instance, and it silently shrinks the usable pool each time instances are replaced.

`prod_query.sh` self-heals: after picking a working host it routes `ssh-keygen -R` through that host (they share the bastion's `known_hosts`), in a single hop for all the addresses it needs to clear. Three things to know:

- **Only genuinely outdated keys are removed.** A candidate is cleared only when SSH's own error names that address and says the identification changed. A plain timeout, a container that is still starting, or a network blip leaves the recorded key alone — throwing away a correct host key would give up real protection against someone impersonating that address. Note the bastion's onward hop usually just *warns* about a changed key and connects anyway — recycled IPs make that the steady state — so a warn-and-proceed failure stays on the patient-retry list too (the key gets cleared, but it isn't why the probe failed). Only an outright `Host key verification failed` refusal disqualifies a candidate from the retry.

- **You cannot run a command on the bastion itself.** It auto-jumps to whatever `LC_PAPER` names; omitting `LC_PAPER` fails with `ssh: Could not resolve hostname`. Always route through a working instance IP.
- **The warning text is often noise.** A run can print the whole man-in-the-middle banner for a *previous* hop and still succeed. Judge by exit code and `MARK` output, not the banner.

- **The self-heal needs one working hop, so it cannot rescue a fully-rejected pool.** `ssh-keygen -R` is routed through the instance that answered. If every candidate is rejected there is no hop to route through, the keys stay stale, and the next run is rejected identically — the pool stops decaying only while something still answers.

### "No instance passed the health probe" usually means slow, not down

The candidate probe is deliberately impatient (20s) so one hung host cannot eat the caller's budget, but that also rejects hosts which are merely slow under load. When *every* candidate fails, a fleet-wide outage is the less likely reading.

`prod_query.sh` now retries the non-stale-key rejections with a patient probe before giving up, and says so (`answered on the patient retry (slow, not unhealthy)`). Only the all-rejected path pays for this.

Both passes draw down one shared **90s selection budget** (`PROD_SELECT_BUDGET`), so picking a host can never consume the caller's whole ~120s Bash-tool window before the query starts — a large pool shortens each probe rather than adding to the total. A third of the budget is held back for the patient pass, so a pool of slow hosts cannot drain everything in the fast pass and starve the retry. Running out gives a distinct message that says the pool may just be slow, instead of the misleading "no instance passed the health probe". Raise the budget when you have more wall clock than the Bash tool allows:

```bash
PROD_SELECT_BUDGET=240 timeout 560 bash .agents/skills/gumroad-prod-console/scripts/prod_query.sh q.rb
```

If you still get the hard error, force a host rather than assuming production is down:

```bash
PROD_INSTANCE_IP=10.1.34.180 bash .agents/skills/gumroad-prod-console/scripts/prod_query.sh q.rb
```

This matters for **watchers**, not just interactive use: a cron that treats an unreadable console as "nothing to report" goes silent indefinitely and looks healthy. On 2026-07-29 all 8 candidates were rejected while a forced host answered the same query in 13s.

### Grepping only for `^MARK` can hide a total failure

`... | grep "^MARK"` on a run that never reached Rails returns empty with **exit 0**, which reads as "query worked, no rows". Capture to files and echo the exit code:

```bash
timeout 560 prod_query.sh /tmp/q.rb > /tmp/q.out 2>/tmp/q.err; echo "exit=$?"
grep -a "^MARK" /tmp/q.out
```

Exit `124` = outer timeout (query too heavy); `255` = SSH failed before Rails started.

### Keep Stripe API calls out of loops

The DB is fast; `Stripe::Transfer.list` / `Charge.retrieve` per record is what blows the timeout — even ~5 accounts with one Stripe call each can hit exit `124`. Use raw SQL via `ActiveRecord::Base.connection.select_all` for population questions, and fetch at most 1–2 Stripe objects per run when you need live processor state.

## Requirements

- An AWS profile with `ec2:DescribeInstances` on the prod account. The script defaults to the profile `gumroad-prod` (created by `scripts/setup.sh`). Override by exporting `AWS_PROFILE` or setting `PROD_AWS_PROFILE` in your config file.
- SSH access to your production bastion (defaults to `bastion-production.gumroad.net`)

### Gumroad team one-time setup

If you previously ran this script via `GUMROAD_DEPLOYMENT_DIR` and `.env.aws`, run the helper from the repo root to migrate those creds into an AWS CLI profile:

```bash
.claude/skills/gumroad-prod-console/scripts/setup.sh
# or pass an explicit path:
.claude/skills/gumroad-prod-console/scripts/setup.sh ~/path/to/.env.aws
```

The helper will also offer to append `export AWS_PROFILE=gumroad-prod` to your shell profile — say yes and reload the shell. After this, `gumroad-deployment` is no longer required to run the skill.

## Configuration (self-hosters)

Defaults target Gumroad's prod infra. If you're running your own Gumroad fork, override by creating `~/.config/gumroad-prod-console.env`:

```bash
PROD_BASTION=bastion.mycompany.com
PROD_SECURITY_GROUP=my-web-sg
PROD_CONTAINER_FILTER=app-*
PROD_DB_HOST_VAR=MY_READ_REPLICA_HOST
PROD_AWS_PROFILE=my-aws-profile
```

Or export the same variables before invoking the script.
