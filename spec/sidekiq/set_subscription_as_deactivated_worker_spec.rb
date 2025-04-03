# frozen_string_literal: true

require "spec_helper"

describe SetSubscriptionAsDeactivatedWorker do
  describe "#perform" do
    it "sets subscription as deactivated" do
      product = create(:membership_product)
      purchase = create(:membership_purchase, link: product)
      subscription = purchase.subscription
      subscription.update!(cancelled_at: 1.day.ago)
      described_class.new.perform(subscription.id)
      expect(subscription.reload.deactivated_at).not_to eq(nil)
    end

    it "does not set subscriptions cancelled in the future as deactivated" do
      subscription = create(:subscription, cancelled_at: 1.day.from_now)
      described_class.new.perform(subscription.id)
      expect(subscription.reload.deactivated_at).to eq(nil)
    end

    it "does not set alive subscription as deactivated" do
      subscription = create(:subscription)
      described_class.new.perform(subscription.id)
      expect(subscription.reload.deactivated_at).to eq(nil)
    end
  end
end
