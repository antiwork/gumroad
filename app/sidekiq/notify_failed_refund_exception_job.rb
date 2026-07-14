# frozen_string_literal: true

class NotifyFailedRefundExceptionJob
  include Sidekiq::Job

  sidekiq_options retry: 10, queue: :default, lock: :until_executed

  def perform(exception_id)
    failed_refund_exception = FailedRefundException.find(exception_id)
    return unless failed_refund_exception.state == "pending"
    return if failed_refund_exception.notification_sent_at.present?
    # Past the cap, delivery is considered broken: stop retrying and leave
    # the row for the dispatcher to escalate through a channel that isn't email.
    return if failed_refund_exception.notification_failures >= FailedRefundException::MAX_NOTIFICATION_FAILURES

    message = notification_message(failed_refund_exception)
    begin
      InternalNotificationMailer.notify(
        room_name: failed_refund_exception.notification_room,
        sender: "Failed Refund Exception",
        message_text: message
      ).deliver_now
    rescue
      # Count only completed delivery failures. Incrementing before deliver_now would
      # let the dispatcher mistake an in-flight final attempt for an exhausted one.
      failed_refund_exception.increment!(:notification_failures)
      raise
    end
    failed_refund_exception.update!(notification_sent_at: Time.current)

    # Secondary channel only, and deliberately last and rescued: notification_sent_at
    # is the durability marker, so a raise here would fail the job into a retry that
    # no-ops on the sent guard — the Sentry event would be lost either way, but the
    # retry would waste an attempt and mislead the retry metrics.
    begin
      ErrorNotifier.notify(message, context: notification_context(failed_refund_exception))
    rescue => e
      Rails.logger.error("NotifyFailedRefundExceptionJob: Sentry capture failed for exception #{failed_refund_exception.id}: #{e.message}")
    end
  end

  private
    def notification_message(failed_refund_exception)
      refund = failed_refund_exception.refund
      purchase = refund.purchase

      "Refund failed after acceptance; the buyer was NOT made whole. #{handling_summary(failed_refund_exception)} " \
        "Exception ##{failed_refund_exception.id} is assigned to #{failed_refund_exception.owner}, " \
        "with a target response by #{failed_refund_exception.due_at.iso8601}. " \
        "Refund #{refund.id} (#{refund.processor_refund_id}), purchase #{purchase.external_id}, " \
        "seller #{purchase.seller_id}. Review buyer communication, re-refund, subscription state, " \
        "payout effects, and any fee or tax side effects."
    end

    def handling_summary(failed_refund_exception)
      refund = failed_refund_exception.refund
      unless failed_refund_exception.balance_reversed?
        return "Nothing was reversed automatically. Review the exception before changing any ledger, payout, dispute, or buyer state."
      end

      summary = "Balance debits recorded on the refund were reversed automatically."
      # The retained processor fee is debited through a separate Credit; the automatic
      # reversal gives it back with an offset credit linked via failed_refund.
      # Legacy rows handled before that existed may still be short the fee, so report
      # what actually happened for THIS refund instead of assuming.
      retained_fee_cents = refund.retained_fee_cents.to_i
      if retained_fee_cents > 0
        if Credit.where(fee_retention_refund: refund).failed_refund_fee_reversals.exists?
          summary += " The #{retained_fee_cents}-cent processor fee retained via a separate credit was also given back to the seller."
        else
          summary += " The #{retained_fee_cents}-cent processor fee retained via a separate credit was NOT reversed; the seller is still debited that fee, and a re-refund will retain it again."
        end
      end
      summary
    end

    def notification_context(failed_refund_exception)
      refund = failed_refund_exception.refund
      purchase = refund.purchase
      {
        failed_refund_exception_id: failed_refund_exception.id,
        owner: failed_refund_exception.owner,
        notification_room: failed_refund_exception.notification_room,
        due_at: failed_refund_exception.due_at,
        refund_id: refund.id,
        processor_refund_id: refund.processor_refund_id,
        purchase_id: purchase.id,
        purchase_external_id: purchase.external_id,
        seller_id: purchase.seller_id,
        refund_amount_cents: refund.amount_cents,
        presentment_currency: refund.presentment_currency,
        presentment_amount_cents: refund.presentment_amount_cents,
        balance_reversed: failed_refund_exception.balance_reversed?,
        retained_fee_cents: refund.retained_fee_cents.to_i,
      }
    end
end
