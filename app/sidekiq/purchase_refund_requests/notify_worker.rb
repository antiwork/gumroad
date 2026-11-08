# frozen_string_literal: true

# Delivers the seller + support notifications for a refund request, idempotent
# on the *_notified_at stamps so retries, duplicate enqueues, and manual
# re-enqueues (notifications_pending?) never double-send.
class PurchaseRefundRequests::NotifyWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  def perform(refund_request_id)
    refund_request = PurchaseRefundRequest.find_by(id: refund_request_id)
    return if refund_request.nil? || !refund_request.open?
    # The flag can be turned off between enqueue and execution; a hard no-op
    # also covers the "queued mail survives flag-off" hole at this layer.
    return unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

    if refund_request.seller_notified_at.nil?
      ContactingCreatorMailer.refund_requested(refund_request.id).deliver_now
      refund_request.update_column(:seller_notified_at, Time.current)
    end

    if refund_request.support_notified_at.nil?
      SupportContactMailer.contact_form(
        email: refund_request.email,
        category: "purchases & refunds",
        message: support_message(refund_request),
      ).deliver_now
      refund_request.update_column(:support_notified_at, Time.current)
    end
  end

  private
    def support_message(refund_request)
      purchase = refund_request.purchase
      <<~MESSAGE
        Buyer refund request ##{refund_request.id} (automated copy for visibility; the seller was notified and has #{PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS} business days to respond).

        Purchase: #{purchase.external_id}
        Product: #{purchase.link.name}
        Amount: #{purchase.formatted_display_price}
        Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
        Message: #{refund_request.message.presence || "(none)"}
      MESSAGE
    end
end
