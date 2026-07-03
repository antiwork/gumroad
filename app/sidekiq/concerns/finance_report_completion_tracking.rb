# frozen_string_literal: true

# Records a "last completed at" timestamp in Redis whenever a finance report job finishes
# successfully. VerifyFinanceReportsDeliveryJob (the daily backstop) compares these
# timestamps against each job's schedule to catch runs that silently never happened —
# e.g. a Sidekiq process killed mid-deploy losing the job entirely, so retries (and the
# retry-exhaustion alert) never fire.
#
# Completions are keyed by class AND the run's resolved period args (explicit perform
# args, or the job's `.default_alert_args` for a no-arg scheduled run). This way a manual
# re-run for a DIFFERENT period (e.g. a TaxJar month re-push) can't mask a missed
# scheduled run — the scheduled period's own key stays stale and the backstop still
# catches it.
#
# Completion is recorded only when #perform returns without raising.
module FinanceReportCompletionTracking
  REDIS_KEY_TTL = 120.days # covers a full quarterly cadence with room to spare

  def self.redis_key(class_name, period_args)
    "finance_report_last_completed_at:#{class_name}:#{Array(period_args).join(',')}"
  end

  def self.last_completed_at(class_name, period_args)
    timestamp = $redis.get(redis_key(class_name, period_args))
    timestamp && Time.zone.at(timestamp.to_i)
  end

  def self.record_completion(class_name, period_args, at: Time.current)
    $redis.set(redis_key(class_name, period_args), at.to_i, ex: REDIS_KEY_TTL.to_i)
  end

  module PerformWrapper
    def perform(*args)
      super.tap do
        klass = self.class
        period_args = args.presence ||
          (klass.respond_to?(:default_alert_args) ? klass.default_alert_args : [])
        FinanceReportCompletionTracking.record_completion(klass.name, period_args)
      end
    end
  end

  def self.included(base)
    base.prepend(PerformWrapper)
  end
end
