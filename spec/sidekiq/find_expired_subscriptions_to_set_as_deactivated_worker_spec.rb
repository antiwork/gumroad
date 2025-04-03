# frozen_string_literal: true

require "spec_helper"

describe FindExpiredSubscriptionsToSetAsDeactivatedWorker do
  describe "#perform" do
    it "queues subscriptions that should be set as deactivated" do
      subscriptions = [
        create(:subscription),
        create(:subscription, cancelled_at: 1.day.from_now),
        create(:subscription, cancelled_at: 1.day.ago, is_test_subscription: true),
        create(:subscription, cancelled_at: 1.day.ago, deactivated_at: 1.hour.ago),
        create(:subscription, cancelled_at: 1.day.ago),
        create(:subscription, failed_at: 1.day.ago),
        create(:subscription, ended_at: 1.day.ago),
      ]

      described_class.new.perform

      expect(SetSubscriptionAsDeactivatedWorker).not_to have_enqueued_sidekiq_job(subscriptions[0].id)
      expect(SetSubscriptionAsDeactivatedWorker).not_to have_enqueued_sidekiq_job(subscriptions[1].id)
      expect(SetSubscriptionAsDeactivatedWorker).not_to have_enqueued_sidekiq_job(subscriptions[2].id)
      expect(SetSubscriptionAsDeactivatedWorker).not_to have_enqueued_sidekiq_job(subscriptions[3].id)
      expect(SetSubscriptionAsDeactivatedWorker).to have_enqueued_sidekiq_job(subscriptions[4].id)
      expect(SetSubscriptionAsDeactivatedWorker).to have_enqueued_sidekiq_job(subscriptions[5].id)
      expect(SetSubscriptionAsDeactivatedWorker).to have_enqueued_sidekiq_job(subscriptions[6].id)
    end
  end
end
