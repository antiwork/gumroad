# frozen_string_literal: true

class FreeTrialExpiringReminderWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return unless subscription.alive?(include_pending_cancellation: false) &&
                  subscription.in_free_trial? &&
                  !subscription.is_test_subscription?


    SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer",
                                           "free_trial_expiring_soon",
                                           subscription_id) do
      CustomerLowPriorityMailer.free_trial_expiring_soon(subscription_id).deliver_later(queue: "low")
    end
  end
end
