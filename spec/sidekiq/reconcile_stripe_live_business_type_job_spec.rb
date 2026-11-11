# frozen_string_literal: true

require "spec_helper"

describe ReconcileStripeLiveBusinessTypeJob do
  let(:user) { create(:user) }

  before { create(:merchant_account, user:) }

  it "reconciles the seller while holding their row lock" do
    create(:user_compliance_info, user:)
    locked = false
    track_lock = ->(*, payload) { locked ||= payload[:sql].match?(/FROM `users`.*FOR UPDATE/m) }
    expect(StripeMerchantAccountManager).to receive(:reconcile_live_business_type).with(user) { expect(locked).to be(true) }

    ActiveSupport::Notifications.subscribed(track_lock, "sql.active_record") { described_class.new.perform(user.id) }
  end

  it "does nothing for a user that no longer exists" do
    expect(StripeMerchantAccountManager).not_to receive(:reconcile_live_business_type)

    described_class.new.perform(0)
  end

  it "leaves a business seller's Stripe account alone" do
    create(:user_compliance_info_business, user:)
    expect(Stripe::Account).not_to receive(:retrieve)
    expect(Stripe::Account).not_to receive(:update)

    described_class.new.perform(user.id)
  end
end
