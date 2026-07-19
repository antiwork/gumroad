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
#
# Escalation notifications are flood-proofed: when many rows cross their deadline in
# the same run (for example a backfill creating hundreds of rows with the same
# due_at), one digest email and one Sentry event summarize all of them instead of
# one per row. Each row still transitions individually with its real reason, so the
# durable audit trail is identical either way — only the notification is batched.
class DispatchPendingFailedRefundExceptionsJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # How many escalations a single run may notify about individually before
  # switching to one digest notification. The per-row email is the right level of
  # detail for the normal trickle (an escalation or two per day), but any bulk
  # event — like the 2026-07-19 backfill where ~2,000 historical rows crossed
  # their 24-hour deadline within the same hour — would otherwise send one email
  # and one Sentry event per row and flood both channels. At or below this count
  # a run behaves exactly as before; above it, the run sends a single digest.
  ESCALATION_DIGEST_THRESHOLD = 5

  def perform
    FailedRefundException.notification_deliverable.find_each do |failed_refund_exception|
      NotifyFailedRefundExceptionJob.perform_async(failed_refund_exception.id)
    end

    # Collect every row that needs escalating before notifying, so the run knows
    # the total count and can pick per-row versus digest notification. A row can
    # match both scopes (delivery exhausted AND past its deadline); it is
    # escalated once, with the delivery-exhausted reason taking precedence
    # because a broken mailer is the more actionable problem.
    escalations = []
    seen_ids = Set.new

    FailedRefundException.delivery_exhausted.find_each do |failed_refund_exception|
      next unless seen_ids.add?(failed_refund_exception.id)
      escalations << Escalation.new(
        failed_refund_exception,
        :delivery_exhausted,
        "Notification delivery failed #{failed_refund_exception.notification_failures} times; the internal mailer needs attention."
      )
    end

    FailedRefundException.overdue.find_each do |failed_refund_exception|
      next unless seen_ids.add?(failed_refund_exception.id)
      escalations << Escalation.new(
        failed_refund_exception,
        :overdue,
        "Response SLA breached: due by #{failed_refund_exception.due_at.iso8601} and still pending."
      )
    end

    if escalations.size <= ESCALATION_DIGEST_THRESHOLD
      escalations.each { |escalation| escalate(escalation.row, reason: escalation.reason) }
    else
      escalate_with_digest(escalations)
    end
  end

  private
    Escalation = Struct.new(:row, :kind, :reason)

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

      deliver_escalation_email(
        room_name: failed_refund_exception.notification_room,
        message_text: message,
        log_label: "exception #{failed_refund_exception.id}"
      )

      failed_refund_exception.escalate!(resolution: reason)
    end

    # Bulk path: one Sentry event and one digest email per notification room
    # (normally a single room) summarizing every escalation in this run. Rows are
    # still escalated one by one with their individual reasons afterwards, so
    # nothing about the durable per-row state differs from the per-row path.
    def escalate_with_digest(escalations)
      rows = escalations.map(&:row)
      ids = rows.map(&:id)
      due_ats = rows.map(&:due_at)
      owners = rows.map(&:owner).tally
      exhausted_count = escalations.count { |escalation| escalation.kind == :delivery_exhausted }
      overdue_count = escalations.size - exhausted_count
      # Sum through a query instead of loading every associated refund into memory;
      # a digest can cover thousands of rows.
      total_refund_amount_cents = FailedRefundException.where(id: ids).joins(:refund).sum("refunds.amount_cents")

      message = "#{rows.size} failed-refund exceptions escalated in one dispatcher run " \
        "(#{exhausted_count} with notification delivery exhausted, #{overdue_count} past their response SLA). " \
        "IDs #{ids.min}–#{ids.max}, owners: #{owners.map { |owner, count| "#{owner} (#{count})" }.join(", ")}, " \
        "due between #{due_ats.min.iso8601} and #{due_ats.max.iso8601}, " \
        "refund amounts totaling #{total_refund_amount_cents} cents. " \
        "Per-row notifications were replaced by this digest to avoid flooding; " \
        "each exception row records its own escalation reason."

      # Same ordering rationale as the per-row path: Sentry first and unrescued,
      # email second and rescued, state transitions last.
      ErrorNotifier.notify(
        message,
        context: {
          escalated_count: rows.size,
          delivery_exhausted_count: exhausted_count,
          overdue_count: overdue_count,
          failed_refund_exception_id_min: ids.min,
          failed_refund_exception_id_max: ids.max,
          owners: owners,
          oldest_due_at: due_ats.min,
          newest_due_at: due_ats.max,
          total_refund_amount_cents: total_refund_amount_cents,
        }
      )

      # Rows can be assigned to different notification rooms; each room gets the
      # digest once so no owning team misses the alert. In practice all rows share
      # the default room and this sends exactly one email.
      rows.map(&:notification_room).uniq.each do |room_name|
        deliver_escalation_email(
          room_name: room_name,
          message_text: message,
          log_label: "digest of #{rows.size} exceptions"
        )
      end

      escalations.each { |escalation| escalation.row.escalate!(resolution: escalation.reason) }
    end

    def deliver_escalation_email(room_name:, message_text:, log_label:)
      InternalNotificationMailer.notify(
        room_name: room_name,
        sender: "Failed Refund Exception",
        message_text: message_text
      ).deliver_now
    rescue => e
      # Expected when escalating because delivery is broken; Sentry already fired.
      Rails.logger.error("DispatchPendingFailedRefundExceptionsJob: escalation email failed for #{log_label}: #{e.message}")
    end
end
