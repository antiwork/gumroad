# frozen_string_literal: true

require "spec_helper"

describe ReconcileStripeLiveBusinessTypeJob do
  let(:user) { create(:user) }
  let!(:merchant_account) { create(:merchant_account, user:) }

  def stub_live_business_type(business_type)
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).and_return(
      Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, object: "account", business_type:)
    )
  end

  def user_lock?(payload) = payload[:sql].match?(/FROM `users`.*FOR UPDATE/m)

  it "reconciles the seller under their row lock when Stripe holds a non-individual type" do
    create(:user_compliance_info, user:)
    stub_live_business_type("non_profit")

    locked = false
    track_lock = ->(*, payload) { locked ||= user_lock?(payload) }
    expect(StripeMerchantAccountManager).to receive(:reconcile_live_business_type).with(user) { expect(locked).to be(true) }

    ActiveSupport::Notifications.subscribed(track_lock, "sql.active_record") { described_class.new.perform(user.id) }
  end

  it "takes no lock and makes no update when Stripe already holds an individual" do
    create(:user_compliance_info, user:)
    stub_live_business_type("individual")
    expect(Stripe::Account).not_to receive(:update)

    locked = false
    track_lock = ->(*, payload) { locked ||= user_lock?(payload) }

    ActiveSupport::Notifications.subscribed(track_lock, "sql.active_record") { described_class.new.perform(user.id) }

    expect(locked).to be(false)
  end

  it "reports a Stripe read failure instead of raising" do
    create(:user_compliance_info, user:)
    allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::APIConnectionError, "timeout")
    expect(ErrorNotifier).to receive(:notify).with(an_instance_of(Stripe::APIConnectionError), context: { user_id: user.id })

    expect { described_class.new.perform(user.id) }.not_to raise_error
  end

  it "makes no Stripe call for a user that no longer exists" do
    expect(Stripe::Account).not_to receive(:retrieve)

    described_class.new.perform(0)
  end

  it "makes no Stripe call for a business seller" do
    create(:user_compliance_info_business, user:)
    expect(Stripe::Account).not_to receive(:retrieve)
    expect(Stripe::Account).not_to receive(:update)

    described_class.new.perform(user.id)
  end
end
