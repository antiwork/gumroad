# frozen_string_literal: true

class FightDisputesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  TERMINAL_DISPUTE_STATES = %w[won lost closed].freeze

  def perform
    DisputeEvidence.not_resolved.includes(:dispute).find_each do |dispute_evidence|
      next if dispute_evidence.hours_left_to_submit_evidence.positive?
      next if TERMINAL_DISPUTE_STATES.include?(dispute_evidence.dispute.state)
      FightDisputeJob.perform_async(dispute_evidence.dispute.id)
    end
  end
end
