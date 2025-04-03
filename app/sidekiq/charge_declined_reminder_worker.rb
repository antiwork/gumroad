# frozen_string_literal: true

class ChargeDeclinedReminderWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return if !subscription.alive?(include_pending_cancellation: false) ||
              subscription.is_test_subscription ||
              !subscription.overdue_for_charge?

    CustomerLowPriorityMailer.subscription_card_declined_warning(subscription_id).deliver_later(queue: "low")
  end
end
