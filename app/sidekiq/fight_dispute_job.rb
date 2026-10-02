# frozen_string_literal: true

class FightDisputeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  CUSTOMER_COMMUNICATION_OMITTED_MESSAGE = "Submitted without the seller's customer communication file: it exceeds the processor's page limit."

  def perform(dispute_id)
    dispute = Dispute.find(dispute_id)
    dispute_evidence = dispute.dispute_evidence
    return if dispute_evidence.resolved?
    # Exact comparison, not hours_left_to_submit_evidence or the rounded window: rounding closed
    # this gate up to 29 minutes before the real deadline. Nothing is forwarded before the window
    # closes even when the seller has already saved a statement: they keep the whole window to
    # revise it, and Stripe accepts one submission.
    return if DisputeEvidence.window_open?(dispute_evidence.seller_contacted_at)

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

    omitted_fields = Array.wrap(disputable.fight_chargeback)
    if omitted_fields.include?(:customer_communication)
      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_SUBMITTED,
        error_message: CUSTOMER_COMMUNICATION_OMITTED_MESSAGE
      )
      ContactingCreatorMailer.chargeback_evidence_file_omitted(dispute.id).deliver_later
    else
      dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
    end
  rescue ChargeProcessorInvalidRequestError => e
    if rejected?(e.message)
      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_REJECTED,
        error_message: e.message
      )
    elsif already_submitted?(e.message)
      # A retry after an update that reached Stripe but whose response never came back.
      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_SUBMITTED,
        error_message: e.message.truncate(255)
      )
      if e.omitted_evidence_fields.include?(:customer_communication)
        ContactingCreatorMailer.chargeback_evidence_file_omitted(dispute.id).deliver_later
      end
    else
      raise e
    end
  end

  private
    def rejected?(message)
      message.include?("This dispute is already closed")
    end

    def already_submitted?(message)
      message.include?("maximum number of evidence submissions")
    end
end
