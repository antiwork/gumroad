# frozen_string_literal: true

class FindExpiredSubscriptionsToSetAsDeactivatedWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform
    now = Time.current
    relations = [
      Subscription.where("cancelled_at < ? and deactivated_at is null", now).not_is_test_subscription.select(:id),
      Subscription.where("failed_at < ? and deactivated_at is null", now).not_is_test_subscription.select(:id),
      Subscription.where("ended_at < ? and deactivated_at is null", now).not_is_test_subscription.select(:id),
    ]
    relations.each do |relation|
      relation.find_each do |subscription|
        SetSubscriptionAsDeactivatedWorker.perform_async(subscription.id)
      end
    end
  end
end
