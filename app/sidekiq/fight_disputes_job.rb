# frozen_string_literal: true

class FightDisputesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  TERMINAL_DISPUTE_STATES = %w[won lost closed].freeze

  def perform
    # Only evidence whose seller window has been opened. hours_left_to_submit_evidence is 0 while
    # seller_contacted_at is NULL, so an unannounced row would otherwise read as ready and be
    # submitted before the seller was ever asked — and CreateMissingDisputeEvidenceJob, which owns
    # those rows, would then reselect a resolved one and email a window that no longer exists.
    DisputeEvidence.seller_contacted.not_resolved.includes(:dispute).find_each do |dispute_evidence|
      next if dispute_evidence.hours_left_to_submit_evidence.positive?
      next if TERMINAL_DISPUTE_STATES.include?(dispute_evidence.dispute.state)
      FightDisputeJob.perform_async(dispute_evidence.dispute.id)
    end
  end
end
