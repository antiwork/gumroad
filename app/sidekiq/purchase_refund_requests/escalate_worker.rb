# frozen_string_literal: true

# Enforces the "creator has 2 business days, then Gumroad support steps in"
# promise: scheduled at creation for the deadline; if the request is still
# open when it fires, it expires the request and tells support to act.
class PurchaseRefundRequests::EscalateWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(refund_request_id)
    refund_request = PurchaseRefundRequest.find_by(id: refund_request_id)
    return if refund_request.nil?

    refund_request.with_lock do
      return unless refund_request.open?

      refund_request.update!(state: "expired")
    end

    purchase = refund_request.purchase
    SupportContactMailer.contact_form(
      email: refund_request.email,
      category: "purchases & refunds",
      message: <<~MESSAGE,
        Buyer refund request ##{refund_request.id}: the seller did not respond within #{PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS} business days. Needs action.

        Purchase: #{purchase.external_id}
        Product: #{purchase.link.name}
        Amount: #{purchase.formatted_display_price}
        Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
      MESSAGE
    ).deliver_now
  end
end
