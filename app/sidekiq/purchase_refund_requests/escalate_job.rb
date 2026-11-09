# frozen_string_literal: true

class PurchaseRefundRequests::EscalateJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(refund_request_id)
    with_primary_database do
      refund_request = PurchaseRefundRequest.find_by(id: refund_request_id)
      next if refund_request.nil? || !refund_request.open?

      purchase = refund_request.purchase
      next unless Feature.active?(:buyer_refund_requests, purchase.seller)
      # Backstop for a missed refund/chargeback sync: close the request instead of escalating it.
      next if refund_request.close_if_purchase_resolved!

      # Email first, escalate second: a failed delivery leaves the request open, so
      # the retry (or the next DispatchPendingJob run) sends it again.
      mail = SupportContactMailer.contact_form(
        email: refund_request.email,
        category: PurchaseRefundRequest::SUPPORT_CATEGORY,
        message: <<~MESSAGE,
          Buyer refund request ##{refund_request.id} is still open after #{PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS} business days. Needs action.

          Purchase: #{purchase.external_id}
          Product: #{purchase.link.name}
          Amount: #{purchase.formatted_display_price}
          Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
          Refunded so far: #{purchase.stripe_partially_refunded? ? "partially" : "nothing"}
          Message: #{refund_request.message.presence || "(none)"}
          Seller notified: #{refund_request.seller_notified_at? ? "yes" : "not yet (still retrying), so contact the seller directly"}
        MESSAGE
      ).deliver_now
      # RescueSmtpErrors returns a rejected send instead of raising it.
      raise mail if mail.is_a?(Exception)

      refund_request.with_lock do
        # The escalation email is support's notice, so a still-owed support copy is not sent later.
        refund_request.update!(state: "escalated", support_notified_at: refund_request.support_notified_at || Time.current) if refund_request.open?
      end
      # Tells the buyer, and sends the seller email if it is still owed.
      PurchaseRefundRequests::NotifyJob.perform_async(refund_request.id)
    end
  end
end
