# frozen_string_literal: true

require "spec_helper"

describe Onetime::DisableRecurringSubscriptionNotifications do
  it "disables recurring subscription charge email and push for users that have them enabled" do
    user1 = create(:user)
    # Explicitly enable both flags (email may be disabled by default for new users)
    user1.enable_recurring_subscription_charge_email = true
    user1.enable_recurring_subscription_charge_push_notification = true
    user1.save!

    user2 = create(:user)
    # Enable only push on second user; email remains as-is (default may already be false)
    user2.enable_recurring_subscription_charge_push_notification = true
    user2.save!

    user3 = create(:user)
    # Already disabled for both
    user3.enable_recurring_subscription_charge_email = false
    user3.enable_recurring_subscription_charge_push_notification = false
    user3.save!

    described_class.process

    expect(user1.reload.enable_recurring_subscription_charge_email).to be(false)
    expect(user1.enable_recurring_subscription_charge_push_notification).to be(false)

    expect(user2.reload.enable_recurring_subscription_charge_email).to be(false)
    expect(user2.enable_recurring_subscription_charge_push_notification).to be(false)

    expect(user3.reload.enable_recurring_subscription_charge_email).to be(false)
    expect(user3.enable_recurring_subscription_charge_push_notification).to be(false)
  end
end
