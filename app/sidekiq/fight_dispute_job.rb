# frozen_string_literal: true

class FightDisputeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(dispute_id)
    dispute = Dispute.find(dispute_id)
    dispute_evidence = dispute.dispute_evidence
    return if dispute_evidence.resolved?
    # Raw arithmetic, not hours_left_to_submit_evidence: that reports 0 once the submission is spent,
    # and this guard exists to hold a not-yet-submitted row until its window closes. The seller's own
    # submit path calls this deliberately early, which is why the not_seller_submitted? half is here.
    return if dispute_evidence.not_seller_submitted? &&
      DisputeEvidence.hours_left_in_window(dispute_evidence.seller_contacted_at).positive?

    disputable = dispute.disputable
    if disputable.charge_processor_transaction_id.blank?
      error_message = "Missing charge processor transaction ID on #{disputable.class.name}##{disputable.id}."
      ErrorNotifier.notify("FightDisputeJob: #{error_message} (dispute_id=#{dispute.id})")
      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_REJECTED,
        error_message:
      )
      return
    end

    disputable.fight_chargeback
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
    def rejected?(message)
      message.include?("This dispute is already closed")
    end
end
