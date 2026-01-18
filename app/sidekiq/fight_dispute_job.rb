# frozen_string_literal: true

class FightDisputeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(dispute_id)
    dispute = Dispute.find(dispute_id)
    dispute_evidence = dispute.dispute_evidence
    return if dispute_evidence.resolved?
    return if dispute_evidence.not_seller_submitted? && dispute_evidence.hours_left_to_submit_evidence.positive?

    dispute.disputable.fight_chargeback
    dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
  rescue ChargeProcessorInvalidRequestError => e
    if rejected?(e.message)
      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_REJECTED,
        error_message: e.message
      )
    else
      raise e
    end
  end

  private
    REJECTION_PATTERNS = [
      "This dispute is already closed",
      "DISPUTE_NOT_ELIGIBLE_FOR_EVIDENCE",
      "DISPUTE_ALREADY_RESOLVED",
      "EVIDENCE_ALREADY_PROVIDED",
      "DISPUTE_LIFE_CYCLE_STAGE_INVALID",
    ].freeze

    def rejected?(message)
      REJECTION_PATTERNS.any? { |pattern| message.include?(pattern) }
    end
end
