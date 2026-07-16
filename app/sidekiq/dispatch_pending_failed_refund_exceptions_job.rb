# frozen_string_literal: true

# Safety net for the failed-refund exception queue. Runs every minute and:
#
# 1. Re-enqueues notifications whose enqueue was lost in the narrow window between
#    the exception row committing and perform_async running (the durable row is the
#    source of truth, so a process exit there cannot permanently lose the alert).
# 2. Escalates exceptions whose notification delivery has exhausted its failure cap
#    — at that point the mailer is considered broken, so email cannot be the channel
#    that reports the problem; Sentry is used instead.
# 3. Escalates exceptions still pending past their response deadline (due_at), so
#    the SLA recorded on the row is enforced rather than being a promise in an email.
class DispatchPendingFailedRefundExceptionsJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform
    FailedRefundException.notification_deliverable.find_each do |failed_refund_exception|
      NotifyFailedRefundExceptionJob.perform_async(failed_refund_exception.id)
    end

    FailedRefundException.delivery_exhausted.find_each do |failed_refund_exception|
      escalate(
        failed_refund_exception,
        reason: "Notification delivery failed #{failed_refund_exception.notification_failures} times; the internal mailer needs attention."
      )
    end

    FailedRefundException.overdue.find_each do |failed_refund_exception|
      escalate(
        failed_refund_exception,
        reason: "Response SLA breached: due by #{failed_refund_exception.due_at.iso8601} and still pending."
      )
    end
  end

  private
    def escalate(failed_refund_exception, reason:)
      message = "Failed-refund exception ##{failed_refund_exception.id} escalated. #{reason} " \
        "Refund #{failed_refund_exception.refund_id}, owner #{failed_refund_exception.owner}."

      # Sentry goes first and unrescued: for delivery-exhausted rows the mailer is
      # the failing component, so it cannot be the only escalation channel. If Sentry
      # itself raises, the row stays pending and the next run retries the escalation.
      ErrorNotifier.notify(
        message,
        context: {
          failed_refund_exception_id: failed_refund_exception.id,
          refund_id: failed_refund_exception.refund_id,
          owner: failed_refund_exception.owner,
          notification_room: failed_refund_exception.notification_room,
          due_at: failed_refund_exception.due_at,
          notification_failures: failed_refund_exception.notification_failures,
        }
      )

      begin
        InternalNotificationMailer.notify(
          room_name: failed_refund_exception.notification_room,
          sender: "Failed Refund Exception",
          message_text: message
        ).deliver_now
      rescue => e
        # Expected when escalating because delivery is broken; Sentry already fired.
        Rails.logger.error("DispatchPendingFailedRefundExceptionsJob: escalation email failed for exception #{failed_refund_exception.id}: #{e.message}")
      end

      failed_refund_exception.escalate!(resolution: reason)
    end
end
