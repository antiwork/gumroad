# frozen_string_literal: true

class FightDisputesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  def perform
    DisputeEvidence.not_resolved.find_each do |dispute_evidence|
      next if dispute_evidence.hours_left_to_submit_evidence.positive?
      FightDisputeJob.perform_async(dispute_evidence.dispute.id)
    end
  end
end
