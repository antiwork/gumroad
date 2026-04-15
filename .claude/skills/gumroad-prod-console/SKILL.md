---
name: gumroad-prod-console
description: >
  Execute read-only Ruby/Rails commands against Gumroad's production database for debugging
  and investigation. Use when the user needs to debug production issues, look up data,
  investigate user reports, check records, or query production state. Triggers on: "check in
  prod", "debug this in prod", "look up user/purchase/product in production", "production
  console", "investigate in prod", "query production", "what's happening in prod", or any
  request to examine live Gumroad production data.
---

# Gumroad Production Console

Read-only Rails runner execution against the production read replica.

## Execution

Run Ruby code via the bundled script:

```bash
# Inline code
~/.claude/skills/gumroad-prod-console/scripts/prod_query.sh 'puts User.count'

# From file
~/.claude/skills/gumroad-prod-console/scripts/prod_query.sh /tmp/query.rb

# From stdin
echo 'puts User.count' | ~/.claude/skills/gumroad-prod-console/scripts/prod_query.sh
```

For multi-line queries, write a temp `.rb` file then pass its path to the script.

The script connects via SSH through the bastion to a Docker container running Puma, executes `rails runner` against the **read replica** (`DATABASE_WORKER_REPLICA1_HOST`), and returns output.

**Timeout**: ~120s default via Bash tool. For queries that may be slow, wrap in `WithMaxExecutionTime.timeout_queries(seconds: 30) { ... }`.

## Safety Rules

- **Read-only**: All queries hit the read replica. Never attempt writes, updates, or deletes.
- **Limit results**: Always use `.limit()`, `.first()`, or `.take()`. Never dump unbounded queries.
- **Use `.pluck`** for lightweight lookups instead of loading full AR objects.
- **No PII in output**: Avoid printing full emails, addresses, or payment details to the console. Truncate or mask when needed.
- **Check `.explain`** before running queries on large tables without indexed conditions.

## Output Format

Always use structured output for parseability:

```ruby
# Good - JSON for complex data
puts user.attributes.slice("id", "name", "created_at").to_json

# Good - inspect for simple values
puts [user.id, user.name].inspect

# Good - pluck for tabular data
puts User.where(...).limit(10).pluck(:id, :email, :created_at).map(&:inspect).join("\n")
```

## Looking up records by external ID

Most models (Purchase, User, Link, etc.) use the `ExternalId` module. Admin URLs and public-facing IDs use **external IDs** (Base64-encoded strings like `aBcDeFgHiJkLmNoPqRsTuQ==`), NOT the integer primary key.

- **Always use `find_by_external_id("...")`** when looking up a record from a URL or external reference.
- **Never use `find("...")`** with an external ID string — `find` interprets it as a primary key lookup and will return the wrong record.

```ruby
# CORRECT — from an admin URL like /admin/purchases/<external_id>
Purchase.find_by_external_id("aBcDeFgHiJkLmNoPqRsTuQ==")

# WRONG — this finds by integer primary key, returning a completely different record
Purchase.find("aBcDeFgHiJkLmNoPqRsTuQ==")
```

## Key Models

| Model | Description | Key lookups |
|---|---|---|
| `User` | Creator/seller accounts | `find_by_external_id`, `find_by(email:)` |
| `Purchase` | Transactions/sales | `find_by_external_id`, `where(email:)`, `where(link_id:)` |
| `Link` (aka Product) | Products/digital goods | `find_by_external_id`, `find_by(unique_permalink:)` |
| `Installment` | Subscriptions/recurring | `where(link_id:, alive: true)` |
| `Balance` | Financial balances | `where(user_id:)` |
| `Dispute` | Chargebacks | `where(purchase_id:)` |
| `CustomDomain` | Branded domains | `find_by(domain:)` |
| `Follower` | Creator followers | `where(followed_id:)` |
| `Comment` | Admin notes on records | `where(commentable_type:, commentable_id:)` — use `content` field (not `body`) |
| `MerchantAccount` | Payment processor accounts | `where(user_id:, charge_processor_id:)` |

## Sidekiq Queues

| Queue | Job limit | Purpose |
|-------|-----------|---------|
| `critical` | 12k | Payouts, webhooks, push notifications, receipts |
| `default` | 300k | General work |
| `long` | — | Longer-running jobs (e.g., PDF stamping) |
| `low` | — | Low priority (e.g., expiry jobs) |

Queue limits: `app/controllers/healthcheck_controller.rb:28`. Worker queue ordering: `docker/web/sidekiq_worker.sh`.

For common query patterns and utilities (DevTools, Flipper, Sidekiq), see [references/common-queries.md](references/common-queries.md).

## Workflow

1. Understand what the user wants to investigate
2. Read relevant model files in `app/models/` if needed to understand schema/associations
3. Write a Ruby snippet (multi-line → temp file, single-line → inline argument)
4. Execute via `prod_query.sh`
5. Parse output and report findings
6. Iterate if more data is needed
