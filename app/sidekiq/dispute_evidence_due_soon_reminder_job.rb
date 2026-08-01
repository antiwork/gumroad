# frozen_string_literal: true

class DisputeEvidenceDueSoonReminderJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  def perform(dispute_id)
    ContactingCreatorMailer.chargeback_evidence_due_soon(dispute_id).deliver_later(queue: "default")
  end
end
