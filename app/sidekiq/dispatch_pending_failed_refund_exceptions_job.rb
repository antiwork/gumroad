# frozen_string_literal: true

# Safety net for the failed-refund exception queue. Runs every minute and:
#
# 1. Re-enqueues Sentry reports whose enqueue was lost in the narrow window between
#    the exception row committing and perform_async running (the durable row is the
#    source of truth, so a process exit there cannot permanently lose the alert).
# 2. Escalates exceptions whose Sentry reporting has exhausted its failure cap.
# 3. Escalates exceptions still pending past their response deadline (due_at), so
#    the SLA recorded on the row is enforced rather than being a promise in an alert.
#
# All reporting is Sentry-only — no email. These are operational error conditions,
# not correspondence (decision: Sahil, 2026-07-19, after the 2026-07-18 backfill's
# 1,975 rows crossed their SLA in the same hour and the per-row email version sent
# ~2,000 messages to the finance inbox). Sentry groups repeated events natively,
# so a bulk SLA crossing shows up as one issue with a count, not an inbox flood.
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
        reason: "Sentry reporting failed #{failed_refund_exception.notification_failures} times; the error reporter needs attention."
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

      # Unrescued on purpose: if Sentry itself raises, the row stays pending and
      # the next run retries the escalation, so the signal cannot be silently lost.
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

      failed_refund_exception.escalate!(resolution: reason)
    end
end
