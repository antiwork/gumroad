# Sidekiq

- If you want to deduplicate a job (using https://github.com/mhenrixon/sidekiq-unique-jobs), 99% of the time, you’re looking for `lock: :until_executed`. It is fast because it works by maintaining a Redis Set of job digests: If a job digest is in this list (`O(1)`), running `perform_async` will be a noop and will return `nil`.
  Furthermore, you likely should **NOT** use `on_conflict: :replace`, because for it to remove an existing enqueued job, it needs to find it first, by scrolling through the Scheduled Set, which is CPU expensive and slow. It also means that `perform_async` will be as slow as the length of the queue, or fail entirely ⇒ you can break Sidekiq but just having one job like this enqueued too often.
- Use scripts in the `app/services/onetime` folder

View the backtrace of a dead job of class `ExportUserSalesDataWorker` with the first argument as `123` in Sidekiq:

```ruby
ds = Sidekiq::DeadSet.new
dead_jobs = ds.select { |job| job.klass == 'ExportUserSalesDataWorker' && job.args[0] == 123 }
pp dead_jobs.first.error_backtrace; nil
```

# DANGER

---

## Removing a lot of jobs from Sidekiq

Situation: You've queued a lot of Sidekiq jobs at once, but you're now realizing one of the following:

- They're too slow
- You put them in the wrong queue
- There are too many of them

All of which can result in delays in the execution of more important jobs.

A solution may be to just remove those jobs.

For example, if you want to delete all jobs from the queue `default` for the worker class `ElasticsearchIndexerWorker`, for the index `Purchase::Indices::V999`, you can do this:

```ruby
def delete_batch_of_jobs
  i = 0
  queue = Sidekiq::Queue.new('default')
  jobs = []
  queue.each do |job|
    if job.klass == "ElasticsearchIndexerWorker" && job.args[1]['class_name'] == 'Purchase::Indices::V999'
      i += 1
      jobs << job
      break if i == 500
    end
  end
  jobs.each(&:delete)
  i
end

def delete_jobs_with_running_total
  total = 0
  loop do
    deleted = delete_batch_of_jobs
    total += deleted
    puts "[#{Time.now}] Total deleted: #{total}"
    break if deleted == 0
  end
  total
end

delete_jobs_with_running_total
```

Origins: https://gumroad.slack.com/archives/C0B4VNR0B/p1591816778064300

## Queuing batches of long running jobs

Situation: we need to run the [`AnnualPayoutExportWorker` job](https://github.com/antiwork/gumroad/blob/main/app/sidekiq/annual_payout_export_worker.rb) for all creators that have received at least one payout last year, so we can send them out the year in review email afterward.

<aside>
🚨 It’s best to have this reviewed by at least one engineer who’s already done this before. Add the script in a `Post-deploy` section of a GitHub issue or PR (if it’s a new Sidekiq worker), so this can be reviewed and approved or improved.

</aside>

This script will enqueue jobs progressively so we can monitor the effect of enqueuing long running jobs and adapt live:

[](https://github.com/gumroad/web/pull/24939#issuecomment-1404714940)
