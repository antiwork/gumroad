# frozen_string_literal: true

require "test_helper"

class SetSubscriptionAsDeactivatedWorkerTest < ActiveSupport::TestCase
  self.described_class = SetSubscriptionAsDeactivatedWorker



  context_ SetSubscriptionAsDeactivatedWorker do
  context_ "#perform" do
  test "sets subscription as deactivated" do
        product = create(:membership_product)
        purchase = create(:membership_purchase, link: product)
        subscription = purchase.subscription
        subscription.update!(cancelled_at: 1.day.ago)
        described_class.new.perform(subscription.id)
        expect(subscription.reload.deactivated_at).not_to eq(nil)
      end

  test "does not set subscriptions cancelled in the future as deactivated" do
        subscription = create(:subscription, cancelled_at: 1.day.from_now)
        described_class.new.perform(subscription.id)
        expect(subscription.reload.deactivated_at).to eq(nil)
      end

  test "does not set alive subscription as deactivated" do
        subscription = create(:subscription)
        described_class.new.perform(subscription.id)
        expect(subscription.reload.deactivated_at).to eq(nil)
      end
    end
  end
end
