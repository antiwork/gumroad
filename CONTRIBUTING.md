# Contributing to Gumroad

## Testing Guidelines

- Don't use "should" in test descriptions
- Write descriptive test names that explain the behavior being tested
- Group related tests together
- Keep tests independent and isolated
- For API endpoints, test response status, format, and content
- Use factories for test data instead of creating objects directly

## Pull Request

1. Update documentation if you're changing behavior
2. Add or update tests for your changes
3. Provide before & after screenshots/videos for UI changes
4. Include screenshots of your test suite passing locally
5. Use native-sounding English in all communication with no excessive capitalization (e.g HOW IS THIS GOING), multiple question marks (how's this going???), grammatical errors (how's dis going), or typos (thnx fr update).
   - ❌ Before: "is this still open ?? I am happy to work on it ??"
   - ✅ After: "Is this actively being worked on? I've started work on it here…"
6. Make sure all tests pass
7. Request a review from maintainers
8. After reviews begin, avoid force-pushing to your branch
   - Force-pushing rewrites history and makes review threads hard to follow
   - Don't worry about messy commits - we squash everything when merging to main
9. The PR will be merged once you have the sign-off of at least one other developer

## Style Guide

- Follow the existing code patterns
- Use clear, descriptive variable names

## Development Guidelines

### Code Standards

- Always use the latest version of Ruby, Rails, TypeScript, and React
- Sentence case headers and buttons and stuff, not title case
- Always write the code
- Don't leave comments in the code
- No explanatory comments please
- Don't apologize for errors, fix them

### Sidekiq Job Guidelines

- The Sidekiq queue names in decreasing order of priority are `critical`, `default`, `low`, and `mongo`. When creating a Sidekiq job select the lowest priority queue you think the job would be ok running in. Most queue latencies are good enough for background jobs. Unless the job is time-sensitive `low` is a good choice otherwise use `default`. The `critical` queue is reserved for receipt/purchase emails and you will almost never need to use it. `mongo` is sort of legacy and we only use it for one-time scripts/bulk migrations/internal tooling.
- New Sidekiq job class names should end with "Job". For example `ProcessBacklogJob`, `CalculateProfitJob`, etc.
- If you want to deduplicate a job (using sidekiq-unique-jobs), 99% of the time, you're looking for `lock: :until_executed`. It is fast because it works by maintaining a Redis Set of job digests: If a job digest is in this list (`O(1)`), running `perform_async` will be a noop and will return `nil`.
- Furthermore, you likely should **NOT** use `on_conflict: :replace`, because for it to remove an existing enqueued job, it needs to find it first, by scrolling through the Scheduled Set, which is CPU expensive and slow. It also means that `perform_async` will be as slow as the length of the queue, or fail entirely ⇒ you can break Sidekiq but just having one job like this enqueued too often.

### Code Patterns and Conventions

- Prefer re-using deprecated boolean flags (https://github.com/pboling/flag_shih_tzu) instead of creating new ones. Deprecated flags are named `DEPRECATED_<something>`. To re-use this flag you'll first need to reset the values for it on staging and production and then rename the flag to the new name. You can reset the flag like this:
  ```ruby
  # flag to reset - `Link.DEPRECATED_stream_only`
  Link.where(Link.DEPRECATED_stream_only_condition).find_in_batches do |batch|
    ReplicaLagWatcher.watch
    puts batch.first.id
    Link.where(id: batch.map(&:id)).update_all(Link.set_flag_sql(:DEPRECATED_stream_only, false))
  end
  ```
- Use `import debounce from "lodash/debounce"` instead of `import { debounce } from "lodash"` because tree-shaking doesn't work well with Lodash.
- Use `product` instead of `link` in new code (in variable names, column names, comments, etc.)
- Use `request` instead of `$.ajax` in new code
- Use `buyer` and `seller` when naming variables instead of `customer` and `creator`
- Avoid `unless`
- Don't create new files in `app/modules/` as it is a legacy location. Prefer creating concerns in the right directory instead (eg: `app/controllers/concerns/`, `app/models/concerns/`, etc.)
- Do not create methods ending in `_path` or `_url`. They might cause collisions with rails generated named route helpers in the future. Instead, use a module similar to `CustomDomainRouteBuilder`
- Use Nano IDs to generate external/public IDs for new models.

### Testing Standards

- Don't start Rspec test names with "should". See https://www.betterspecs.org/#should
- Use `@example.com` for emails in tests
- Use `example.com`, `example.org`, and `example.net` as custom domains or request hosts in tests.
- Avoid `to_not have_enqueued_sidekiq_job` or `not_to have_enqueued_sidekiq_job` because they're prone to false positives. Make assertions on `SidekiqWorkerName.jobs.size` instead.

### Feature Development

- Use feature flags for new features
- Do not perform "backfilling" type of operations via ActiveRecord callbacks, whether you're enqueuing a job or not to create missing values. Use a Onetime task instead.
  - This is because we have a lot of users, products, and data.
  - Example: If you enqueue a backfilling job for each user upon them being updated, it's likely going to result in enqueuing millions of jobs in an uncontrollable way, potentially crashing Sidekiq (redis would be out of memory), and/or clogging the queues because each of these jobs takes "a few seconds" (= way too slow) and/or create massive uncontrollable replica lag, etc.
- Use scripts in the `app/services/onetime` folder

## Writing Bug Reports

A great bug report includes:

- A quick summary and/or background
- Steps to reproduce
  - Be specific!
  - Give sample code if you can
- What you expected would happen
- What actually happens
- Notes (possibly including why you think this might be happening, or stuff you tried that didn't work)

## Writing commit messages

We use the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

A commit message should be structured as follows:

```bash
type(scope): title

description
```

Where type can be:

- `feat`: new feature or enhancement
- `fix`: bug fixes
- `docs`: documentation-only changes
- `test`: test-only changes
- `refactor`: code improvements without behaviour changes
- `chore`: maintenance/anything else

Example:

```
feat(cli): Add mobile testing support
```

## Help

- Check existing discussions/issues/PRs before creating new ones
- Start a discussion for questions or ideas
- Open an [issue](https://github.com/antiwork/gumroad/issues) for bugs or problems
- Any issue with label `help wanted` is open for contributions - [view open issues](https://github.com/antiwork/gumroad/issues?q=state%3Aopen%20label%3A%22help%20wanted%22)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE.md).
