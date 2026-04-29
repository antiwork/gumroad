---
name: email-blast
description: >
  Send one-off email blasts to Gumroad creators directly via production console, no PR or
  deploy needed. Handles drafting, recipient query, count validation via Metabase, dry-run
  preview, and execution. Use when asked to "email creators", "send an announcement",
  "blast sellers", "notify users", or any request to send emails to Gumroad creators at scale.
---

# Email Blast

Send one-off emails to Gumroad creators by executing Ruby inline against the production console. No PR, no deploy, no service class needed.

## Prerequisites

- Production console access configured via the `gumroad-prod-console` skill (see its SKILL.md for setup)
- Metabase API key (in 1Password: "Metabase (Gumroad)" → "API Key")

All production Ruby execution in this skill goes through `.claude/skills/gumroad-prod-console/scripts/prod_query.sh`. That script targets the read replica for MySQL, which is sufficient here — `User.alive.not_suspended...find_each` is a read, and `deliver_later` + `$redis.set` hit Redis, not MySQL. Do not add any MySQL-write operations to blast scripts.

## Workflow

### 1. Clarify the request

From the human's request, extract:
- **Who** — recipient criteria (e.g. "all active creators", "creators who earned > $1000")
- **What** — the message to send (subject + body)
- **Reply-to** — default `support@gumroad.com`

### 2. Draft the email

Write a `subject` and HTML `body`:
- Simple HTML only: `<p>` tags, `<a>` links
- Sign off: `<p>— The Gumroad Team</p>`
- No `<ul>`/`<li>` (renders poorly). Use `<p>• Item</p>` for bullets.
- Keep it short and direct
- **Always use** `from: "Gumroad <gumroad@creators.gumroad.com>"` and `sender_domain: :creators`
- The OneOffMailer template renders the subject as an `<h2>` heading at the top automatically

**Present the draft for human approval before proceeding.**

### 3. Count recipients via Metabase

Build a SQL query and validate the count:
```bash
METABASE_KEY=$(op item get "Metabase (Gumroad)" --vault Gumclaw --fields "API Key" --reveal)
curl -s -X POST "https://gumroad.metabaseapp.com/api/dataset" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $METABASE_KEY" \
  -d '{
    "database": 2,
    "type": "native",
    "native": { "query": "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL AND is_suspended = 0 AND ..." }
  }' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['rows'][0][0])"
```

**Always filter**: `deleted_at IS NULL AND is_suspended = 0` (alive, not suspended).

Show the count to the human before executing.

### 4. Dry run (preview)

Generate a script that sends to just 1-2 test recipients first. Run via `prod_query.sh`:
```bash
cat << 'RUBY' | .claude/skills/gumroad-prod-console/scripts/prod_query.sh
test_user = User.find_by(email: "sahil@gumroad.com")
OneOffMailer.email(
  email: test_user.form_email,
  from: "Gumroad <gumroad@creators.gumroad.com>",
  subject: "SUBJECT HERE",
  body: <<~HTML,
    <p>Body here.</p>
    <p>— The Gumroad Team</p>
  HTML
  reply_to: "support@gumroad.com",
  sender_domain: :creators
).deliver_later(queue: "low")
puts "Test email enqueued to #{test_user.form_email}"
RUBY
```

**Wait for human confirmation that the test email looks good before proceeding.**

### 5. Execute the blast

Generate the full script with Redis checkpointing for resumability:

```bash
cat << 'RUBY' | .claude/skills/gumroad-prod-console/scripts/prod_query.sh
redis_key = "email_blast_DESCRIPTIVE_KEY_last_user_id"
last_processed_id = $redis.get(redis_key).to_i
count = 0

User.alive.not_suspended.where("id > ?", last_processed_id).where(CRITERIA).find_each(batch_size: 500) do |user|
  next if user.form_email.blank?

  OneOffMailer.email(
    email: user.form_email,
    from: "Gumroad <gumroad@creators.gumroad.com>",
    subject: "SUBJECT",
    body: <<~HTML,
      <p>Body here.</p>
      <p>— The Gumroad Team</p>
    HTML
    reply_to: "support@gumroad.com",
    sender_domain: :creators
  ).deliver_later(queue: "low")

  $redis.set(redis_key, user.id)
  count += 1
  Rails.logger.info "Enqueued email for user #{user.id} (#{count} total)" if count % 100 == 0
end

puts "Done. Enqueued #{count} emails."
RUBY
```

### 6. Resume / Reset

- **Resume** (if interrupted): Just re-run the same script. Redis checkpoint skips already-processed users.
- **Reset** (to re-send): Delete the Redis key first:
  ```bash
  echo '$redis.del("email_blast_DESCRIPTIVE_KEY_last_user_id")' | .claude/skills/gumroad-prod-console/scripts/prod_query.sh
  ```

## Safety Rules

1. **Always get human approval** on subject, body, and recipient count before executing
2. **Always send a dry-run** to a test recipient first (sahil@gumroad.com or the requester)
3. **Always use Redis checkpointing** — blasts can be interrupted and resumed
4. **Always use `deliver_later(queue: "low")`** — never `deliver_now` (would block the runner)
5. **Always filter** `alive.not_suspended` and `form_email.present?`
6. **Never send from** `hi@customers.gumroad.com` — that's for transactional emails only
7. **Log progress** so you can verify emails are being enqueued

## Key References

- `OneOffMailer`: `app/mailers/one_off_mailer.rb`
- Example service: `app/services/onetime/notify_sellers_about_legacy_fee_migration.rb`
- `form_email`: The user's preferred contact email (may differ from login email)
- Sender domains: `:creators` → `creators.gumroad.com`, default → `customers.gumroad.com`
