- Always use the latest version of Ruby, Rails, TypeScript, and React
- Sentence case headers and buttons and stuff, not title case
- Always write the code
- Don't leave comments in the code
- No explanatory comments please
- Don't apologize for errors, fix them
- Prefer re-using deprecated boolean flags (https://github.com/pboling/flag_shih_tzu) instead of creating new ones. Deprecated flags are named `DEPRECATED_<something>`. To re-use this flag you'll first need to reset the values for it on staging and production and then rename the flag to the new name. You can reset the flag like this:
    
    ```ruby
    # flag to reset - `Link.DEPRECATED_stream_only`
    Link.where(Link.DEPRECATED_stream_only_condition).find_in_batches do |batch|
      ReplicaLagWatcher.watch
      puts batch.first.id
      Link.where(id: batch.map(&:id)).update_all(Link.set_flag_sql(:DEPRECATED_stream_only, false))
    end
    ```
- The Sidekiq queue names in decreasing order of priority are `critical`, `default`, `low`, and `mongo`. When creating a Sidekiq job select the lowest priority queue you think the job would be ok running in. Most queue latencies are good enough for background jobs. Unless the job is time-sensitive `low` is a good choice otherwise use `default`. The `critical` queue is reserved for receipt/purchase emails and you will almost never need to use it. `mongo` is sort of legacy and we only use it for one-time scripts/bulk migrations/internal tooling.
- Use `import debounce from "lodash/debounce"` instead of `import { debounce } from "lodash"` because tree-shaking doesn't work well with Lodash. [[ref](https://github.com/gumroad/web/pull/15162)]
- Use `product` instead of `link` in new code (in variable names, column names, comments, etc.)
- Use `request` instead of `$.ajax` in new code
- New Sidekiq job class names should end with "Job". For example `ProcessBacklogJob`, `CalculateProfitJob`, etc.
- Don't start Rspec test names with "should". See https://www.betterspecs.org/#should
- Use `@example.com` for emails in tests
- Use `example.com`,  [`example.org`](http://example.org), and [`example.net`](http://example.net) as custom domains or request hosts in tests.
- Avoid `unless`
- Use `buyer` and `seller` when naming variables instead of `customer` and `creator`
- Don't create new files in `app/modules/` as it is a legacy location. Prefer creating concerns in the right directory instead (eg: `app/controllers/concerns/`, `app/models/concerns/`, etc.)
- Avoid `to_not have_enqueued_sidekiq_job` or `not_to have_enqueued_sidekiq_job` because they're prone to false positives. Make assertions on  `SidekiqWorkerName.jobs.size` instead. See [comment in #20580 for details](https://github.com/gumroad/web/pull/20580#discussion_r716199137).
- Do not create methods ending in `_path` or `_url`. They might cause collisions with rails generated named route helpers in the future. Instead, use a module similar to `CustomDomainRouteBuilder` [[ref](https://github.com/gumroad/web/pull/12281#discussion_r352283892)]
- Use feature flags for new features
- Do not perform "backfilling" type of operations via ActiveRecord callbacks, whether you're enqueuing a job or not to create missing values. Use a Onetime task instead.
    - This is because we have a lot of users, products, and data.
    - Example: If you enqueue a backfilling job for each user upon them being updated, it's likely going to result in enqueuing millions of jobs in an uncontrollable way, potentially crashing Sidekiq (redis would be out of memory), and/or clogging the queues because each of these jobs takes "a few seconds" (= way too slow) and/or create massive uncontrollable replica lag, etc.
- Use Nano IDs to generate external/public IDs for new models.
- If you want to deduplicate a job (using sidekiq-unique-jobs), 99% of the time, you're looking for `lock: :until_executed`. It is fast because it works by maintaining a Redis Set of job digests: If a job digest is in this list (`O(1)`), running `perform_async` will be a noop and will return `nil`.
Furthermore, you likely should **NOT** use `on_conflict: :replace`, because for it to remove an existing enqueued job, it needs to find it first, by scrolling through the Scheduled Set, which is CPU expensive and slow. It also means that `perform_async` will be as slow as the length of the queue, or fail entirely ⇒ you can break Sidekiq but just having one job like this enqueued too often.
- Use scripts in the `app/services/onetime` folder
- When adding new rules, update both .cursorrules and .github/copilot-instructions.md to keep them synchronized
