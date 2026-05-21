# frozen_string_literal: true

class FightDisputeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(dispute_id)
    dispute = Dispute.find(dispute_id)
    dispute_evidence = dispute.dispute_evidence
    return if dispute_evidence.resolved?
    return if dispute_evidence.not_seller_submitted? && dispute_evidence.hours_left_to_submit_evidence.positive?

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
