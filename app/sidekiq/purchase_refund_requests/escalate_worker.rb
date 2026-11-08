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

      # The support mail IS the escalation, so it is delivered before the expiry
      # is committed. Expiring first (as this used to) made a transient delivery
      # failure unrecoverable: the Sidekiq retry reloaded an expired row, took
      # the `return unless open?` branch above, and support was never told while
      # the buyer's page already said support was on it. Now a failure rolls the
      # expiry back with the request still open, so the retry can finish the job.
      SupportContactMailer.contact_form(
        email: refund_request.email,
        category: "purchases & refunds",
        message: escalation_message(refund_request),
      ).deliver_now

      refund_request.update!(state: "expired")
    end
  end

  private
    def escalation_message(refund_request)
      purchase = refund_request.purchase
      <<~MESSAGE
        Buyer refund request ##{refund_request.id}: the seller did not respond within #{PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS} business days. Needs action.

        Purchase: #{purchase.external_id}
        Product: #{purchase.link.name}
        Amount: #{purchase.formatted_display_price}
        Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
      MESSAGE
    end
end
