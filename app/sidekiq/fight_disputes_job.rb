# frozen_string_literal: true

class FightDisputesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed
  # Scans open dispute evidence hourly and fans out one job per row; the scan is the whole
  # attempt. Hourly leaves the least room of any job here, so the ceiling binds and the TTL
  # lands just under the interval.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 20.minutes

  TERMINAL_DISPUTE_STATES = %w[won lost closed].freeze

  def perform
    # Only evidence whose seller window has been opened. hours_left_to_submit_evidence is 0 while
    # seller_contacted_at is NULL, so an unannounced row would otherwise read as ready and be
    # submitted before the seller was ever asked; CreateMissingDisputeEvidenceJob owns those.
    DisputeEvidence.seller_contacted.not_resolved.includes(:dispute).find_each do |dispute_evidence|
      next if dispute_evidence.hours_left_to_submit_evidence.positive?
      next if TERMINAL_DISPUTE_STATES.include?(dispute_evidence.dispute.state)
      FightDisputeJob.perform_async(dispute_evidence.dispute.id)
    end
  end
end
