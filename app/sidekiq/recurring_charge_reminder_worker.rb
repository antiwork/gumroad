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
    return if kind == ADVANCE && !send_advance?(subscription)

    CustomerLowPriorityMailer.subscription_renewal_reminder(subscription_id).deliver_later(queue: "low")
  end

  private
    # One advance notice per renewal; skipped once the final reminder is due, so a late run never doubles up.
    def send_advance?(subscription)
      renews_at = subscription.end_time_of_subscription
      final_lead = BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence)
      return false if renews_at - final_lead <= Time.current

      $redis.set("renewal_advance_reminder:#{subscription.id}:#{renews_at.to_i}", 1, nx: true, ex: ADVANCE_SENT_TTL.to_i)
    end
end
