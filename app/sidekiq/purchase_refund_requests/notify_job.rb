# frozen_string_literal: true

# At-least-once per recipient: a stamp is written only after its email is handed
# to the transport, so a crash in between re-sends that one email on retry. The
# unique lock is what stops two copies from running at once (sidekiq-unique-jobs
# skips a job whose digest another jid holds). No row lock around delivery: a slow
# mail server would hold the request row and stall the refund sync behind it.
class PurchaseRefundRequests::NotifyJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options retry: 10, queue: :default, lock: :until_executed

  def perform(refund_request_id)
    # The create-time push runs right after the commit, before a replica may have the row.
    with_primary_database do
      refund_request = PurchaseRefundRequest.find_by(id: refund_request_id)
      next if refund_request.nil? || !refund_request.open?
      next unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

      notify(refund_request, :seller_notified_at) do
        ContactingCreatorMailer.refund_requested(refund_request.id)
      end
      notify(refund_request, :support_notified_at) do
        SupportContactMailer.contact_form(
          email: refund_request.email,
          category: PurchaseRefundRequest::SUPPORT_CATEGORY,
          message: support_message(refund_request),
        )
      end
    end
  end

  private
    def notify(refund_request, stamp)
      return if refund_request.public_send(stamp).present?

      mail = yield.deliver_now
      # RescueSmtpErrors returns a rejected send instead of raising it; don't stamp it as sent.
      raise mail if mail.is_a?(Exception)
      # The mailer can also skip the send (e.g. a malformed seller address); leave it owed.
      return unless mail.is_a?(Mail::Message)

      refund_request.update_column(stamp, Time.current)
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
