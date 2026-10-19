# frozen_string_literal: true

class RecurringChargeReminderWorker
  class EmailNotEnqueuedError < StandardError; end

  include Sidekiq::Job
  # The lock digest covers all args, so it serializes copies of one advance job without blocking the final reminder.
  sidekiq_options retry: 3,
                  queue: :default,
                  lock: :while_executing,
                  lock_timeout: 2,
                  unique_across_queues: true,
                  on_conflict: { server: :raise }

  ADVANCE = "advance"

  def perform(subscription_id, kind = nil)
    subscription = Subscription.find(subscription_id)
    return if !subscription.alive?(include_pending_cancellation: false) ||
              subscription.in_free_trial? ||
              subscription.charges_completed? ||
              (subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?) ||
              !subscription.send_renewal_reminders?

    if kind == ADVANCE
      send_advance_notice(subscription) if advance_due?(subscription)
    else
      CustomerLowPriorityMailer.subscription_renewal_reminder(subscription_id).deliver_later(queue: "low")
    end
  end

  private
    # Rejects jobs scheduled for an earlier renewal date or recurrence, and any run once the final reminder is due.
    def advance_due?(subscription)
      lead = BasePrice::Recurrence.renewal_advance_reminder_email_days(subscription.recurrence)
      return false if lead.nil?

      renews_at = subscription.end_time_of_subscription
      now = Time.current
      renews_at - lead <= now && renews_at - BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence) > now
    end

    def send_advance_notice(subscription)
      # A cold replica can still be missing the previous run's marker.
      ApplicationRecord.connected_to(role: :writing) do
        digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "subscription_renewal_reminder", subscription.id, ADVANCE, subscription.end_time_of_subscription.to_i)
        return if SentEmailInfo.key_exists?(digest)

        # A failed enqueue must remain retryable; a crash before the marker can duplicate one notice.
        enqueued = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id).deliver_later(queue: "low")
        raise EmailNotEnqueuedError, "Advance renewal reminder was not enqueued" unless enqueued

        SentEmailInfo.set_key!(digest)
      end
    end
end
