# frozen_string_literal: true

require "spec_helper"

describe SubscriptionEvent do
  describe "creation" do
    it "sets the seller" do
      subscription_event = create(:subscription_event)
      expect(subscription_event.seller).to eq(subscription_event.subscription.seller)
    end

    it "validates the consecutive event_type are not duplicated" do
      subscription = create(:subscription)
      create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 5.days.ago)
      expect { create(:subscription_event, subscription: subscription, event_type: :deactivated) }.to raise_error(ActiveRecord::RecordInvalid)
      create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 4.days.ago)
      expect { create(:subscription_event, subscription: subscription, event_type: :restarted) }.to raise_error(ActiveRecord::RecordInvalid)
      create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 3.days.ago)
      expect { create(:subscription_event, subscription: subscription, event_type: :deactivated) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
