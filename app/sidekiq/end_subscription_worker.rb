# frozen_string_literal: true

class EndSubscriptionWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return if subscription.is_test_subscription?
    return unless subscription.alive?(include_pending_cancellation: false)
    return unless subscription.charges_completed?

    subscription.end_subscription!
  end
end
