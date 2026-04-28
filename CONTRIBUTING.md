# Contributing to Gumroad

## Overall

Use native-sounding English in all communication with no excessive capitalization (e.g HOW IS THIS GOING), multiple question marks (how's this going???), grammatical errors (how's dis going), or typos (thnx fr update).

- ❌ Before: "is this still open ?? I am happy to work on it ??"
- ✅ After: "Is this actively being worked on? I've started work on it here…"

Explain the reasoning behind your changes, not just the change itself. Describe the architectural decision or the specific problem being solved. For bug fixes, identify the root cause. Don't apply a fix without explaining how the invalid state occurred.

## Pull requests

- Include an AI disclosure
- Self-review (comment) on your code
- Break up big 1k+ line PRs into smaller PRs (100 loc)
- **Must**: Include a video for every PR. For user-facing changes, show before/after with light/dark mode and mobile/desktop. For non-user-facing changes, record a short walkthrough of the relevant existing functionality to demonstrate understanding and confirm nothing broke.
- Include updates to any tests, especially end-to-end tests!
- Deploy the app to a preview URL and include QA steps

### PR description structure

Non-trivial PRs should follow this structure:

- **What** — What this PR does. Concrete changes, not a list of files.
- **Why** — Why this change exists and why this approach was chosen over alternatives.
- **Before/After** — Video is required for all PRs. For user-facing changes, show before/after with desktop and mobile, light and dark mode. For non-user-facing changes, include a short video walking through the relevant existing functionality.
- **Test Results** — Screenshot of tests passing locally.

End with an AI disclosure after a `---` separator. Name the specific model (e.g., "Claude Opus 4.6") and list the prompts given to the agent.

## AI models

Use the latest and greatest state-of-the-art models from American AI companies like [Anthropic](https://www.anthropic.com/) and [OpenAI](https://openai.com/). As of this writing, that means Claude Opus 4.6 and GPT-5.4, but always check for the newest releases. Don't settle for last-gen models when better ones are available.

## Development guidelines

### Testing guidelines

- Don't use "should" in test descriptions
- Write descriptive test names that explain the behavior being tested
- Group related tests together
- Keep tests independent and isolated
- For API endpoints, test response status, format, and content
- Use factories for test data instead of creating objects directly
- Tests must fail when the fix is reverted. If the test passes without the application code change, it is invalid.
- Scope VCR cassettes to specific test files. Sharing cassettes across tests causes collisions where tests read incorrect cached responses.
- When your code change causes a spec to follow a new HTTP code path (e.g., removing a guard clause, adding a new API call), run the spec locally to regenerate VCR cassettes. Do not stub external APIs to work around missing cassettes. See [VCR Cassettes](#vcr-cassettes) in docs/testing.md.
- Don't start Rspec test names with "should". See https://www.betterspecs.org/#should
- Use `@example.com` for emails in tests
- Use `example.com`, `example.org`, and `example.net` as custom domains or request hosts in tests.
- Avoid `to_not have_enqueued_sidekiq_job` or `not_to have_enqueued_sidekiq_job` because they're prone to false positives. Make assertions on `SidekiqWorkerName.jobs.size` instead.

### Before pushing

Run **test-confidence** before every commit:

```bash
bin/test-confidence          # Stop at 99%
bin/test-confidence 0.95     # Quick sanity check
bin/test-confidence 1.0      # Run the full suite
bin/test-confidence --no-ai  # No API key needed
```

It ranks every spec by relevance to your diff and runs them in order. Confidence climbs from 0% to 100% in real-time as each test passes. Most relevant tests run first, so confidence front-loads fast. For payment/billing changes it auto-raises the threshold to 100%.

Set `ANTHROPIC_API_KEY` for AI-powered reordering (falls back to convention mapping without it). Also works as a Claude Code skill: `/test-confidence`

Also lint before committing:

```bash
bundle exec rubocop -a              # Ruby lint + auto-correct
DISABLE_TYPE_CHECKED=1 npx eslint   # JS/TS lint
```

Do not push code with failing tests. CI is not a substitute for local verification. Fix any issues before committing.

### Code standards

- Always use the latest version of Ruby, Rails, TypeScript, and React
- Sentence case headers and buttons and stuff, not title case
- Always write the code
- Don't leave comments in the code
- No explanatory comments please
- Don't apologize for errors, fix them
- Business logic (pricing, calculations, discount application) belongs in Rails, not the frontend. The frontend renders state provided by the backend. Enforce all constraints on the server.
- Assign raw numbers to named constants (e.g., `MAX_CHARACTER_LIMIT` instead of `500`) to clarify their purpose.
- Avoid abstracting code into shared components if the duplication is coincidental. If two interfaces look similar but serve different purposes (e.g., Checkout vs. Settings), keep them separate to allow independent evolution.

### Sidekiq jobs

- The Sidekiq queue names in decreasing order of priority are `critical`, `default`, `low`, and `mongo`. When creating a Sidekiq job select the lowest priority queue you think the job would be ok running in. Most queue latencies are good enough for background jobs. Unless the job is time-sensitive `low` is a good choice otherwise use `default`. The `critical` queue is reserved for receipt/purchase emails and you will almost never need to use it. `mongo` is sort of legacy and we only use it for one-time scripts/bulk migrations/internal tooling.
- New Sidekiq job class names should end with "Job". For example `ProcessBacklogJob`, `CalculateProfitJob`, etc.
- If you want to deduplicate a job (using sidekiq-unique-jobs), 99% of the time, you're looking for `lock: :until_executed`. It is fast because it works by maintaining a Redis Set of job digests: If a job digest is in this list (`O(1)`), running `perform_async` will be a noop and will return `nil`.
- Furthermore, you likely should **NOT** use `on_conflict: :replace`, because for it to remove an existing enqueued job, it needs to find it first, by scrolling through the Scheduled Set, which is CPU expensive and slow. It also means that `perform_async` will be as slow as the length of the queue, or fail entirely ⇒ you can break Sidekiq but just having one job like this enqueued too often.

### UI components

- Use the shared UI components in `$app/components/ui/` for all standard UI elements. Do not use native HTML elements like `<table>`, `<input>`, `<select>` when a UI component exists.
- Import them with the `$app` alias: `import { Table } from "$app/components/ui/Table"` (not `<table>`)
- Available components include: `Alert`, `Avatar`, `Calendar`, `Card`, `Checkbox`, `CodeSnippet`, `ColorPicker`, `DefinitionList`, `Details`, `Fieldset`, `FormSection`, `InlineList`, `Input`, `InputGroup`, `Label`, `Menu`, `PageHeader`, `Pill`, `Placeholder`, `ProductCard`, `ProductCardGrid`, `Radio`, `Range`, `Rows`, `Select`, `Sheet`, `StretchedLink`, `Switch`, `Table`, `Tabs`, `Textarea`
- Check what already exists in `app/javascript/components/ui/` before creating new components
- Do not recreate or inline components that already exist in the UI library

### Code patterns

- When creating financial records (receipts, sales), copy the specific values (amount, currency, percentage) at the time of purchase instead of referencing mutable data like a `DiscountCode` ID. This ensures historical records remain accurate if the original object is edited or deleted.
- Do not use database-level foreign key constraints (`add_foreign_key`). Avoiding hard constraints simplifies data migration and sharding operations at scale.
- **Do not add, remove, or rename columns on the `users` or `purchases` tables.** These tables are too large for schema changes. Migrations that alter their schema will block deployments. If you need new data associated with users or purchases, create a new table and reference it. This also applies to adding or removing indexes on these tables.
- Do not use dynamic string interpolation for Tailwind class names (e.g., `` `text-${color}` ``). Tailwind scanners cannot detect these during build. Use full class names or a lookup map.
- Prefer re-using deprecated boolean flags (https://github.com/pboling/flag_shih_tzu) instead of creating new ones. Deprecated flags are named `DEPRECATED_<something>`. To re-use this flag you'll first need to reset the values for it on staging and production and then rename the flag to the new name. You can reset the flag like this:
  ```ruby
  # flag to reset - `Link.DEPRECATED_stream_only`
  Link.where(Link.DEPRECATED_stream_only_condition).find_in_batches do |batch|
    ReplicaLagWatcher.watch
    puts batch.first.id
    Link.where(id: batch.map(&:id)).update_all(Link.set_flag_sql(:DEPRECATED_stream_only, false))
  end
  ```
- Use `product` instead of `link` in new code (in variable names, column names, comments, etc.)
- Use `request` instead of `$.ajax` in new code
- Use `buyer` and `seller` when naming variables instead of `customer` and `creator`
- Don't create new files in `app/modules/` as it is a legacy location. Prefer creating concerns in the right directory instead (eg: `app/controllers/concerns/`, `app/models/concerns/`, etc.)
- Do not create methods ending in `_path` or `_url`. They might cause collisions with rails generated named route helpers in the future. Instead, use a module similar to `CustomDomainRouteBuilder`
- Use Nano IDs to generate external/public IDs for new models.

### Feature development

- Do not perform "backfilling" type of operations via ActiveRecord callbacks, whether you're enqueuing a job or not to create missing values. Use a Onetime task instead.
  - This is because we have a lot of users, products, and data.
  - Example: If you enqueue a backfilling job for each user upon them being updated, it's likely going to result in enqueuing millions of jobs in an uncontrollable way, potentially crashing Sidekiq (redis would be out of memory), and/or clogging the queues because each of these jobs takes "a few seconds" (= way too slow) and/or create massive uncontrollable replica lag, etc.
  - Create scripts in the `app/services/onetime` folder

## Writing issues

Issues for enhancements, features, or refactors use this structure:

### What

What needs to change. Be concrete:

- Describe the current behavior and the desired behavior
- Who is affected (buyers, sellers, internal team)
- Quantify impact with data when possible (error rates, support tickets, revenue)
- Use a checkbox task list for multiple deliverables

### Why

Why this change matters:

- What user or business problem does this solve?
- Link to related issues, support tickets, or prior discussions for context

Keep it short. The title should carry most of the weight — the body adds context the title can't.

## Writing bug reports

A great bug report includes:

- A quick summary and/or background
- Steps to reproduce
  - Be specific!
  - Give sample code if you can
- What you expected would happen
- What actually happens
- Notes (possibly including why you think this might be happening, or stuff you tried that didn't work)

## Help

- Any issue with label `help wanted` is open for contributions - [view open issues](https://github.com/antiwork/gumroad/issues?q=state%3Aopen%20label%3A%22help%20wanted%22)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE.md).
