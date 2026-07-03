# frozen_string_literal: true

# Daily backstop for the scheduler-fired finance report jobs (phase 2 of the robustness
# pass — see FinanceReportFailureAlert).
#
# Retry-exhaustion alerts only fire when Sidekiq gets to run the retries. A run can also
# vanish entirely — a Sidekiq process killed mid-deploy loses the in-flight job, or the
# scheduler tick itself is missed — and then nothing raises, nothing retries, and no alert
# goes out. This job closes that gap: every day it checks, for each scheduler-fired
# finance report job, that a completion was recorded (FinanceReportCompletionTracking)
# for every scheduled fire time since the backstop was activated. If a fire has no
# completion, it re-enqueues the job with arguments pinned to the period the missed run
# was for, and emails the payments notification address so the gap is visible.
#
# Re-enqueueing is safe: every verified job is a read-only aggregation (or, for the
# TaxJar upload, idempotent — already-imported orders are skipped).
class VerifyFinanceReportsDeliveryJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # Only fires older than this are checked, so a run that is merely slow (or scheduled
  # shortly before this backstop) isn't flagged as missing.
  GRACE_PERIOD = 6.hours
  # Set on the backstop's first ever run (which only records the baseline and checks
  # nothing). Fires from before this moment predate completion tracking — the runs may
  # well have completed without leaving a Redis key — so they are skipped instead of
  # being replayed as false positives right after the first deploy.
  ACTIVE_SINCE_REDIS_KEY = "finance_report_backstop_active_since"

  # Scheduler-fired jobs to verify, mapped to a builder for the re-run args pinned to the
  # period the missed fire was for. Fanned-out report jobs (Canada, VAT, fees, ...) are
  # covered transitively: if an orchestrator run vanishes, re-enqueueing the orchestrator
  # re-enqueues them all.
  VERIFIED_JOBS = {
    "SendFinancesReportWorker" => ->(fire_time) { SendFinancesReportWorker.default_alert_args(fire_time) },
    "SendDeferredRefundsReportWorker" => ->(fire_time) { SendDeferredRefundsReportWorker.default_alert_args(fire_time) },
    "SendStripeCurrencyBalancesReportJob" => ->(_fire_time) { [] },
    "EmailOutstandingBalancesCsvWorker" => ->(_fire_time) { [] },
    "CreateIndiaSalesReportJob" => ->(fire_time) { CreateIndiaSalesReportJob.default_alert_args(fire_time) },
    "GenerateFinancialReportsForPreviousMonthJob" => ->(fire_time) { GenerateFinancialReportsForPreviousMonthJob.default_alert_args(fire_time) },
    "GenerateFinancialReportsForPreviousQuarterJob" => ->(fire_time) { GenerateFinancialReportsForPreviousQuarterJob.default_alert_args(fire_time) },
    "UploadUsStatesSalesTaxToTaxjarJob" => ->(fire_time) { [(fire_time.to_date - 1).iso8601] },
  }.freeze

  def perform
    return unless Rails.env.production?

    now = Time.current

    active_since_raw = $redis.get(ACTIVE_SINCE_REDIS_KEY)
    if active_since_raw.nil?
      $redis.set(ACTIVE_SINCE_REDIS_KEY, now.to_i)
      return
    end
    active_since = Time.zone.at(active_since_raw.to_i)

    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
    schedule.each_value do |entry|
      class_name = entry["class"]
      args_builder = VERIFIED_JOBS[class_name]
      next if args_builder.nil?

      # The schedule's cron expressions are documented (and fired in production) in UTC —
      # pin the parse to UTC explicitly so this doesn't drift with server TZ.
      cron = Fugit::Cron.parse("#{entry['cron'].sub(/#.*/, '').strip} UTC")

      # EVERY fire since activation is checked, not just the most recent one. Checking
      # only the latest fire loses older gaps: if the verifier is down while a monthly
      # fire is missed and the NEXT month's fire then completes, a latest-only check sees
      # that newer completion and the older missed month is never re-enqueued or alerted.
      # Each period has its own completion key, so walking back through the fires reads
      # each one independently and a newer completion can't mask an older gap.
      #
      # The walk is bounded (besides by activation) by the completion keys' own lifetime:
      # keys expire after 120 days (FinanceReportCompletionTracking::REDIS_KEY_TTL), so a
      # fire older than that may have completed and had its key expire — unknowable, not
      # missing, same as pre-activation fires. The most recent fire alone is still
      # checked with no age cutoff, so even after a very long outage the newest gap is
      # always caught. Fires from before activation predate completion tracking entirely
      # and are skipped as unknowable, not missing.
      oldest_verifiable_fire = now - FinanceReportCompletionTracking::REDIS_KEY_TTL
      fire_time = cron.previous_time(now - GRACE_PERIOD).to_t.utc
      # Jobs without period args (their builder ignores the fire time) resolve every
      # fire to the same completion key — checking that key once covers the whole walk,
      # and skipping the repeats avoids re-enqueueing the identical job several times.
      seen_period_keys = Set.new
      while fire_time >= active_since
        args = args_builder.call(fire_time)
        if seen_period_keys.add?(FinanceReportCompletionTracking.redis_key(class_name, args))
          verify_fire(class_name, args, fire_time)
        end
        fire_time = cron.previous_time(fire_time).to_t.utc
        break if fire_time < oldest_verifiable_fire
      end
    end
  end

  private
    def verify_fire(class_name, args, fire_time)
      last_completed_at = FinanceReportCompletionTracking.last_completed_at(class_name, args)
      return if last_completed_at && last_completed_at >= fire_time

      # A duplicate enqueue can raise for unique jobs with on_conflict: :raise (e.g.
      # yesterday's backstop re-run is still queued or running). The gap still gets
      # alerted below, and one fire's conflict must not stop the remaining fires and
      # jobs from being verified — so notify and carry on rather than let it bubble.
      begin
        class_name.constantize.perform_async(*args)
      rescue => e
        ErrorNotifier.notify(e, class_name:, fire_time: fire_time.iso8601)
      end

      AccountingMailer.finance_report_delivery_backstop_triggered(
        class_name, args, fire_time, last_completed_at
      ).deliver_later
    end
end
