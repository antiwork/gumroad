# frozen_string_literal: true

class RecurringChargeReminderWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return if !subscription.alive?(include_pending_cancellation: false) ||
              subscription.in_free_trial? ||
              subscription.charges_completed? ||
              !subscription.send_renewal_reminders?

    CustomerLowPriorityMailer.subscription_renewal_reminder(subscription_id).deliver_later(queue: "low")
  end
end
