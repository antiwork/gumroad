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
