# frozen_string_literal: true

# Delivers the seller + support notifications for a refund request, idempotent
# on the *_notified_at stamps so retries, duplicate enqueues, and manual
# re-enqueues (notifications_pending?) never double-send. Each stamp is claimed
# under the request's own row lock, which is what makes two overlapping jobs for
# the same request safe.
class PurchaseRefundRequests::NotifyWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  def perform(refund_request_id)
    refund_request = PurchaseRefundRequest.find_by(id: refund_request_id)
    return if refund_request.nil? || !refund_request.open?
    # The flag can be turned off between enqueue and execution; a hard no-op
    # also covers the "queued mail survives flag-off" hole at this layer.
    return unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

    notify_seller(refund_request)
    notify_support(refund_request)
  end

  private
    # Claim the stamp under the row lock and write it only after the mail has
    # been handed to the transport. Two jobs for the same request can therefore
    # overlap (the post-create redirect re-enqueues while the first is still
    # pending, and the create itself enqueued one) without double-sending: the
    # second blocks on the lock, re-reads the stamp and skips. A delivery that
    # raises rolls the lock back with the stamp unset, so the Sidekiq retry still
    # owes the notification instead of losing it.
    def notify_seller(refund_request)
      refund_request.with_lock do
        next if refund_request.seller_notified_at.present? || !refund_request.open?

        ContactingCreatorMailer.refund_requested(refund_request.id).deliver_now
        refund_request.update_column(:seller_notified_at, Time.current)
      end
    end

    def notify_support(refund_request)
      refund_request.with_lock do
        next if refund_request.support_notified_at.present? || !refund_request.open?

        SupportContactMailer.contact_form(
          email: refund_request.email,
          category: "purchases & refunds",
          message: support_message(refund_request),
        ).deliver_now
        refund_request.update_column(:support_notified_at, Time.current)
      end
    end

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
