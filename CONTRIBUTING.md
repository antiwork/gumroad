# Contributing to Gumroad

## Contributing from a fork

We don't run an inbound review queue on this repo, so external changes come to us a different way:

1. **Fork the repo** and open the pull request on _your own_ fork.
2. **Email [support@gumroad.com](mailto:support@gumroad.com)** with a link to it.
3. We review it ourselves, and if we want it, **we merge it on our side.**

Your PR on your fork is held to the same bar as anything we write. Concretely, at minimum:

- **Visual evidence** for anything a user can see, before/after, desktop + mobile, light + dark. Video preferred. This is the #1 rule below and it is not waived for forks. The one exception is the same one we give ourselves: a PR that only touches documentation or agent skill files needs no video, because the diff is the reviewable artifact.
- **QA steps** someone else can actually follow to verify the change.
- **Test results** — updated tests where appropriate, and the relevant commands/checks run. No screenshot of passing specs or terminal output is required.
- **An AI disclosure** naming the specific model, after a `---` separator.
- **A self-review** comment on your own diff, and a **What / Why / Before-After / Test Results** description.

The rest of the guidelines below apply too, with the obvious substitutions for working outside this repo: reference `qa-media/` files by your own fork's raw URL (`raw.githubusercontent.com/<your-username>/gumroad/<branch>/...`, not `antiwork/gumroad`), name them `pr-<your-fork-pr-number>-<description>`, and skip the steps that depend on this repo's own infrastructure — preview-app deploys need org credentials you won't have, so we run those ourselves once we pull the change in. Substituting for those is expected; skipping the evidence itself is not.

A fork PR that skips the evidence gets the same answer as one of ours that skips it: it isn't ready. If your change is good and documented well, the fork is not a barrier — it's just where the work lives until we pull it in.

**Issues and bug reports are still welcome here.** This is about pull requests only — [file issues](https://github.com/antiwork/gumroad/issues) and bug reports on this repo as normal.

Merged fork commits keep your authorship, so contributions show up under your name in the history. Emailing us a link to your fork PR counts as contributing under the [license terms](#license) at the bottom of this guide.

We read every submission, but we can't promise a reply to each one or a timeline for review.

## Overall

Use native-sounding English in all communication with no excessive capitalization (e.g HOW IS THIS GOING), multiple question marks (how's this going???), grammatical errors (how's dis going), or typos (thnx fr update).

- ❌ Before: "is this still open ?? I am happy to work on it ??"
- ✅ After: "Is this actively being worked on? I've started work on it here…"

Explain the reasoning behind your changes, not just the change itself. Describe the architectural decision or the specific problem being solved. For bug fixes, identify the root cause. Don't apply a fix without explaining how the invalid state occurred.

## Pull requests

> ### ⛔ THE #1 RULE FOR ANY PRODUCT CHANGE: SHOW IT.
>
> **Every PR that changes anything a user can see or experience MUST include before/after visual evidence — a video (preferred) or screenshots — covering desktop + mobile, light + dark where applicable.** This is the single most important requirement of a product PR, above code style, above everything. A "small" mobile/CSS/layout tweak is exactly the kind of change that needs a screenshot or clip — that is the whole point. Do NOT rationalize a visual change as too minor to capture. A product PR without media is not ready to review and should be sent back. Non-visual PRs still need a short walkthrough video (see below) — **except PRs that only modify documentation or agent skill files, where the diff itself is the reviewable artifact and no video is required.**

- Include an AI disclosure
- Self-review (comment) on your code
- Break up big 1k+ line PRs into smaller PRs (100 loc)
- **Must**: Include a video for every PR. For user-facing changes, show before/after with light/dark mode and mobile/desktop. For non-user-facing changes, record a short walkthrough of the relevant existing functionality to demonstrate understanding and confirm nothing broke. Exception: PRs that only touch documentation or agent skill files need no video — the diff is the reviewable artifact.
- Include updates to any tests, especially end-to-end tests!
- Deploy the app to a preview URL and include QA steps

### PR description structure

Non-trivial PRs should follow this structure:

- **What** — What this PR does. Concrete changes, not a list of files.
- **Why** — Why this change exists and why this approach was chosen over alternatives. When other PRs or approaches exist for the same problem, name them and say why this one wins (fewer changes, right API, no backend/storage churn, etc.).
- **Before/After** — Video is required for all PRs, except PRs that only touch documentation or agent skill files, where the diff itself is the reviewable artifact. For user-facing changes, show before/after with desktop and mobile, light and dark mode. For non-user-facing changes, include a short video walking through the relevant existing functionality.
- **Test Results** — List the relevant test commands/checks run. No screenshot of passing specs or terminal output is required.

Store visual evidence screenshots and videos in `qa-media/` using the naming convention `pr-<number>-<description>.<ext>`. From a fork, use your own fork's PR number — it won't match any number here, and that's fine. Reference them in PR descriptions with raw GitHub URLs:

```markdown
![description](https://raw.githubusercontent.com/antiwork/gumroad/<branch>/qa-media/pr-5160-pagination-page1.png)
```

End with an AI disclosure after a `---` separator. Name the specific model (e.g., "Claude Opus 4.6") and list the prompts given to the agent.

## AI models

Use the latest and greatest state-of-the-art models from American AI companies like [Anthropic](https://www.anthropic.com/) and [OpenAI](https://openai.com/). As of this writing, that means Claude Opus 4.6 and GPT-5.4, but always check for the newest releases. Don't settle for last-gen models when better ones are available.

## Development guidelines

See [Parallel local development lanes](docs/local-dev-parallel-lanes.md) to run isolated development environments concurrently.

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
- If a spec moves real money out of the shared Stripe **test** account (a live `Stripe::Transfer`, a real payout), tag it `spend_stripe_balance: true`. That is what tells `StripeBalanceEnforcer` to top the account up before the example runs. Without the tag the spec fails with `balance_insufficient` once the account drains, and `spec/config/stripe_balance_enforcer_gate_spec.rb` will name your file. Prefer VCR or a stub — only reach for the tag when the spec genuinely has to transfer.
- Use `@example.com` for emails in tests
- Use `example.com`, `example.org`, and `example.net` as custom domains or request hosts in tests.
- Avoid `to_not have_enqueued_sidekiq_job` or `not_to have_enqueued_sidekiq_job` because they're prone to false positives. Make assertions on `SidekiqWorkerName.jobs.size` instead.

### Branch hygiene

Rebase your branch onto `main` when starting work and before every commit:

```bash
git fetch origin
git rebase origin/main
```

Resolve conflicts locally before pushing. PRs with stale branches will not be merged.

Working from a fork, `origin` is your fork — and your fork's `main` goes stale the moment this repo moves. Add this repo as `upstream` once (`git remote add upstream https://github.com/antiwork/gumroad.git`) and rebase onto `upstream/main` instead.

### Before pushing

Run **test-confidence** before every commit:

```bash
bin/test-confidence          # Run to 99%, stop
bin/test-confidence --full   # Run to 100%
```

Requires `ANTHROPIC_API_KEY`. Opus 4.7 analyzes your diff in one call: decides the risk level, picks which tests to run, sets the order, and determines how many tests are needed for each confidence milestone. A comment-only change might need 2 tests for 99%. A payment model refactor might need 100. The AI decides the curve shape ad hoc per diff.

The bar is yellow while running toward 99%, then turns green. At green, safe to commit. Also works as a Claude Code skill: `/test-confidence`

Also lint before committing:

```bash
bundle exec rubocop -a              # Ruby lint + auto-correct
DISABLE_TYPE_CHECKED=1 npx eslint   # JS/TS lint
npm run typecheck                   # TS type check
```

Do not push code with failing tests. CI is not a substitute for local verification. Fix any issues before committing.

### Code standards

- Always use the latest version of Ruby, Rails, TypeScript, and React
- Sentence case headers and buttons and stuff, not title case
- Always write the code
- Comments are welcome when they earn their place. Keep them concise and focused on the why — intent, non-obvious trade-offs, edge cases, the reason a surprising line exists. Don't narrate the what the code already says plainly.
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
- **Number migrations with a real UTC timestamp** (`rails g migration` does this; `date -u +%Y%m%d%H%M%S` if you are writing the file by hand). Hand-picked `...000015`-style sequence numbers collide: two open PRs pick the same next number, git sees no conflict because the filenames differ, both merge, and `rake db:prepare` then aborts on `main` for everyone with `Duplicate migration <version>` (PR #6716). `bin/check-migration-versions` runs in CI and catches this; run it locally with no arguments before pushing.
- **A migration whose version has already been deployed cannot be renumbered freely.** Rails keys completion on the version number alone, so a database that recorded the old version treats the renumbered migration as already applied. Make both directions safe: guard `up` on `table_exists?`/`column_exists?`, and have `down` leave the schema in place while the superseded version is still present in `schema_migrations`.
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

- Any issue with label `help wanted` is one we'd welcome a fix for - [view open issues](https://github.com/antiwork/gumroad/issues?q=state%3Aopen%20label%3A%22help%20wanted%22). Work it on your fork and email [support@gumroad.com](mailto:support@gumroad.com) with the link, per [the route at the top of this guide](#contributing-from-a-fork).

## When you're corrected, fix the docs

If a maintainer corrects your approach in review — a convention, a workflow, a gotcha that isn't written down — don't just fix the code. Propose an edit to this guide in the same PR (or a fast follow-up) so the correction is captured once and never has to be repeated. The contributing guide should get a little smarter every time someone gets corrected.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE.md).
