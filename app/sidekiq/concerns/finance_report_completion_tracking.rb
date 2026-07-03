# frozen_string_literal: true

# Records a "last completed at" timestamp in Redis whenever a finance report job finishes
# successfully. VerifyFinanceReportsDeliveryJob (the daily backstop) compares these
# timestamps against each job's schedule to catch runs that silently never happened —
# e.g. a Sidekiq process killed mid-deploy losing the job entirely, so retries (and the
# retry-exhaustion alert) never fire.
#
# Completion is recorded only when #perform returns without raising.
module FinanceReportCompletionTracking
  REDIS_KEY_TTL = 120.days # covers a full quarterly cadence with room to spare

  def self.redis_key(class_name)
    "finance_report_last_completed_at:#{class_name}"
  end

  def self.last_completed_at(class_name)
    timestamp = $redis.get(redis_key(class_name))
    timestamp && Time.zone.at(timestamp.to_i)
  end

  module PerformWrapper
    def perform(*args)
      super.tap do
        $redis.set(
          FinanceReportCompletionTracking.redis_key(self.class.name),
          Time.current.to_i,
          ex: FinanceReportCompletionTracking::REDIS_KEY_TTL.to_i
        )
      end
    end
  end

  def self.included(base)
    base.prepend(PerformWrapper)
  end
end
