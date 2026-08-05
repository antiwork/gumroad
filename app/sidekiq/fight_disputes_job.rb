# frozen_string_literal: true

class FightDisputesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed
  # Scans open dispute evidence hourly and fans out one job per row; the scan is the whole
  # attempt.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 20.minutes

  TERMINAL_DISPUTE_STATES = %w[won lost closed].freeze

  def perform
    # Ask for the raw window, not hours_left_to_submit_evidence: that one reports 0 once the single
    # Stripe submission is spent, which here would mean an already-submitted row read as ready and
    # got forwarded a second time. The scope is filtered on seller_contacted, so a NULL stamp (owned
    # by CreateMissingDisputeEvidenceJob) never reaches window_open?. Exact comparison, not the
    # rounded hours: rounding closed this window up to 29 minutes before the real deadline.
    DisputeEvidence.seller_contacted.not_resolved.includes(:dispute).find_each do |dispute_evidence|
      next if DisputeEvidence.window_open?(dispute_evidence.seller_contacted_at)
      next if TERMINAL_DISPUTE_STATES.include?(dispute_evidence.dispute.state)
      FightDisputeJob.perform_async(dispute_evidence.dispute.id)
    end
  end
end
