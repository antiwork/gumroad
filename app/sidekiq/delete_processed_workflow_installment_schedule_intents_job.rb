# frozen_string_literal: true

class DeleteProcessedWorkflowInstallmentScheduleIntentsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  RETENTION_PERIOD = 30.days

  def perform
    WorkflowInstallmentScheduleIntent
      .where(processed_at: ...RETENTION_PERIOD.ago)
      .in_batches(of: 1_000)
      .delete_all
  end
end
