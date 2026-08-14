# frozen_string_literal: true

class UnsubscribeAndFailWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return if !subscription.alive?(include_pending_cancellation: false) ||
              subscription.is_test_subscription ||
              !subscription.overdue_for_charge?

    subscription.unsubscribe_and_fail!
  end
end
