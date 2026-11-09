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
      next if refund_request.nil? || !refund_request.awaiting_outcome?
      next unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)
      next if refund_request.close_if_purchase_resolved!

      # Each recipient is tried even when an earlier one fails, so one rejected address can't hold
      # back the others; the first failure is re-raised at the end so Sidekiq retries what is still owed.
      # Past the deadline the escalation emails replace the confirmation, which would quote a date
      # already gone, and the support copy, which would duplicate support's notice.
      past_deadline = refund_request.escalation_deadline.past?
      failures = []
      if refund_request.state_escalated?
        failures << notify_buyer(refund_request, :buyer_escalation_notified_at) do
          CustomerLowPriorityMailer.refund_request_escalated(refund_request.id)
        end
      elsif refund_request.open? && !past_deadline
        failures << notify_buyer(refund_request, :buyer_notified_at) do
          CustomerLowPriorityMailer.refund_request_received(refund_request.id)
        end
      end

      seller_failure = notify(refund_request, :seller_notified_at) do
        ContactingCreatorMailer.refund_requested(refund_request.id)
      end
      failures << seller_failure
      # The support copy says whether the seller was reached, so it waits for a run where the seller
      # attempt didn't error; otherwise a passing SMTP blip would tell support to contact the seller.
      unless past_deadline || seller_failure
        failures << notify(refund_request, :support_notified_at) do
          SupportContactMailer.contact_form(
            email: refund_request.email,
            category: PurchaseRefundRequest::SUPPORT_CATEGORY,
            message: support_message(refund_request),
          )
        end
      end

      failure = failures.compact.first
      raise failure if failure
    end
  end

  private
    # The buyer's address never changes, so a malformed one is settled here instead of retried every run.
    def notify_buyer(refund_request, stamp, &)
      return notify(refund_request, stamp, &) if EmailFormatValidator.valid?(refund_request.email)

      refund_request.update_column(stamp, Time.current) if refund_request.public_send(stamp).nil?
      nil
    end

    # Returns the delivery error instead of raising it, so the caller can try the other recipients first.
    def notify(refund_request, stamp)
      return if refund_request.public_send(stamp).present?

      mail = yield.deliver_now
      # RescueSmtpErrors returns a rejected send instead of raising it; don't stamp it as sent.
      return mail if mail.is_a?(Exception)
      # The mailer can also skip the send (e.g. a malformed seller address); leave it owed.
      return unless mail.is_a?(Mail::Message)

      refund_request.update_column(stamp, Time.current)
      nil
    rescue StandardError => e
      e
    end

    def seller_status(refund_request)
      if refund_request.seller_notified_at?
        "the seller was notified and has #{PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS} business days to respond"
      else
        "the seller could not be emailed, so contact them directly"
      end
    end

    def support_message(refund_request)
      purchase = refund_request.purchase
      <<~MESSAGE
        Buyer refund request ##{refund_request.id} (automated copy for visibility; #{seller_status(refund_request)}).

        Purchase: #{purchase.external_id}
        Product: #{purchase.link.name}
        Amount: #{purchase.formatted_display_price}
        Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
        Message: #{refund_request.message.presence || "(none)"}
      MESSAGE
    end
end
