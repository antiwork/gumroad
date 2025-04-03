# frozen_string_literal: true

class SetSubscriptionAsDeactivatedWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)
    return if subscription.alive?
    subscription.deactivate!
  end
end
