# frozen_string_literal: true

# Daily backstop for the scheduler-fired finance report jobs (phase 2 of the robustness
# pass — see FinanceReportFailureAlert).
#
# Retry-exhaustion alerts only fire when Sidekiq gets to run the retries. A run can also
# vanish entirely — a Sidekiq process killed mid-deploy loses the in-flight job, or the
# scheduler tick itself is missed — and then nothing raises, nothing retries, and no alert
# goes out. This job closes that gap: every day it checks, for each scheduler-fired
# finance report job, that a completion was recorded (FinanceReportCompletionTracking)
# after the job's most recent scheduled fire time. If not, it re-enqueues the job with
# arguments pinned to the period the missed run was for, and emails the payments
# notification address so the gap is visible.
#
# Re-enqueueing is safe: every verified job is a read-only aggregation (or, for the
# TaxJar upload, idempotent — already-imported orders are skipped).
class VerifyFinanceReportsDeliveryJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # Only fires older than this are checked, so a run that is merely slow (or scheduled
  # shortly before this backstop) isn't flagged as missing.
  GRACE_PERIOD = 6.hours
  # Only fires within this window are checked. Keeps the first deploy (and any job whose
  # last scheduled fire predates completion tracking) from alerting on missing history,
  # while still checking every fire at least once — this job runs daily, so a miss is
  # seen within ~30 hours of the fire.
  LOOKBACK = 48.hours
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
      fire_time = Fugit::Cron.parse("#{entry['cron'].sub(/#.*/, '').strip} UTC").previous_time(now - GRACE_PERIOD).to_t.utc
      next if fire_time < now - LOOKBACK
      next if fire_time < active_since

      args = args_builder.call(fire_time)
      last_completed_at = FinanceReportCompletionTracking.last_completed_at(class_name, args)
      next if last_completed_at && last_completed_at >= fire_time

      class_name.constantize.perform_async(*args)
      AccountingMailer.finance_report_delivery_backstop_triggered(
        class_name, args, fire_time, last_completed_at
      ).deliver_later
    end
  end
end
