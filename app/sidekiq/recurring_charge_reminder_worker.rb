# frozen_string_literal: true

class RecurringChargeReminderWorker
  class EmailNotEnqueuedError < StandardError; end

  include Sidekiq::Job
  # The lock digest covers all args, so it serializes copies of one job without the advance and final reminders blocking each other.
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

    send_once_per_renewal(subscription, kind) if due?(subscription, kind)
  end

  private
    # Rejects jobs scheduled for an earlier renewal date or recurrence, a final reminder once the renewal has passed,
    # and an advance notice once the final reminder is due.
    def due?(subscription, kind)
      final_lead = BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence)
      lead = kind == ADVANCE ? BasePrice::Recurrence.renewal_advance_reminder_email_days(subscription.recurrence) : final_lead
      return false if lead.nil?

      renews_at = subscription.renews_at
      now = Time.current
      window_ends_at = kind == ADVANCE ? renews_at - final_lead : renews_at
      renews_at - lead <= now && window_ends_at > now
    end

    def send_once_per_renewal(subscription, kind)
      # A cold replica can still be missing the previous run's marker.
      ApplicationRecord.connected_to(role: :writing) do
        digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "subscription_renewal_reminder", subscription.id, kind, subscription.renews_at.to_i)
        return if SentEmailInfo.key_exists?(digest)

        # A failed enqueue must remain retryable; a crash before the marker can duplicate one reminder.
        enqueued = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id).deliver_later(queue: "low")
        raise EmailNotEnqueuedError, "Renewal reminder was not enqueued" unless enqueued

        SentEmailInfo.set_key!(digest)
      end
    end
end
