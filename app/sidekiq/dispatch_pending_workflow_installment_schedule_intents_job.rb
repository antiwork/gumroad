# frozen_string_literal: true

class DispatchPendingWorkflowInstallmentScheduleIntentsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  def perform
    WorkflowInstallmentScheduleIntent.dispatchable.find_each do |intent|
      WorkflowInstallmentScheduleIntent.enqueue(intent.token)
    end
  end
end
