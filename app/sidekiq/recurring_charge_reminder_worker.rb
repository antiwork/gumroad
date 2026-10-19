# frozen_string_literal: true

class RecurringChargeReminderWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  ADVANCE = "advance"
  ADVANCE_SENT_TTL = 60.days

  def perform(subscription_id, kind = nil)
    subscription = Subscription.find(subscription_id)
    return if !subscription.alive?(include_pending_cancellation: false) ||
              subscription.in_free_trial? ||
              subscription.charges_completed? ||
              (subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?) ||
              !subscription.send_renewal_reminders?
    return if kind == ADVANCE && !advance_due?(subscription)

    if kind == ADVANCE
      key = advance_key(subscription)
      return unless $redis.set(key, 1, nx: true, ex: ADVANCE_SENT_TTL.to_i)

      begin
        CustomerLowPriorityMailer.subscription_renewal_reminder(subscription_id).deliver_later(queue: "low")
      rescue
        $redis.del(key)
        raise
      end
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

    def advance_key(subscription)
      "renewal_advance_reminder:#{subscription.id}:#{subscription.end_time_of_subscription.to_i}"
    end
end
