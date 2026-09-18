# frozen_string_literal: true

require "spec_helper"

describe RestoreBankPayoutRail do
  let(:user) { create(:named_user) }
  let!(:compliance_info) { create(:user_compliance_info, user:, country: "India") }
  let!(:merchant_account) { create(:merchant_account, user:) }
  let!(:bank_account) { create(:indian_bank_account, user:, stripe_connect_account_id: merchant_account.charge_processor_merchant_id) }

  def switch_to_paypal!
    params = ActionController::Parameters.new(payment_address: "paypal@example.com", confirm_bank_rail_loss: "true")
    expect(UpdatePayoutMethod.new(user_params: params, seller: user).process).to eq(success: true)
    user.reload
  end

  def stub_stripe_account(**attrs)
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id)
      .and_return(Stripe::Account.construct_from({ id: merchant_account.charge_processor_merchant_id, payouts_enabled: true }.merge(attrs)))
  end

  before { stub_stripe_account }

  it "revives the bank account and merchant account a PayPal switch removed, and clears the PayPal address" do
    switch_to_paypal!
    expect(user.active_bank_account).to be_nil
    expect(user.stripe_account).to be_nil

    result = described_class.new(user:).process

    expect(result.success).to be(true)
    user.reload
    expect(user.active_bank_account).to eq(bank_account)
    expect(user.stripe_account).to eq(merchant_account)
    expect(merchant_account.reload).to have_attributes(deleted_at: nil, charge_processor_deleted_at: nil)
    expect(merchant_account.charge_processor_alive_at).to be_present
    expect(user.payment_address).to be_blank
    expect(user.can_setup_bank_payouts?).to be(true)
  end

  it "refuses where the seller can re-create the rail themselves" do
    compliance_info.mark_deleted!
    create(:user_compliance_info, user:, country: "Egypt")
    switch_to_paypal!

    result = described_class.new(user:).process

    expect(result.error).to eq(:rail_recreatable)
    expect(user.reload.payment_address).to eq("paypal@example.com")
  end

  it "refuses when a bank account is already active" do
    result = described_class.new(user:).process

    expect(result.success).to be(false)
    expect(result.error).to eq(:bank_account_already_active)
  end

  it "refuses when there is nothing to restore" do
    bank_account.destroy!

    result = described_class.new(user:).process

    expect(result.error).to eq(:no_deleted_bank_account)
  end

  # Other flows soft-delete bank rows on their own (country change, payout recovery); only the
  # pair a PayPal switch removed in one go comes back.
  it "refuses a bank account that was not removed together with its merchant account" do
    switch_to_paypal!
    merchant_account.update_columns(charge_processor_deleted_at: 3.days.ago)

    result = described_class.new(user:).process

    expect(result.error).to eq(:not_removed_by_paypal_switch)
    expect(user.reload.active_bank_account).to be_nil
  end

  it "refuses when Stripe no longer has the account, leaving everything deleted" do
    switch_to_paypal!
    stub_stripe_account(deleted: true)

    result = described_class.new(user:).process

    expect(result.error).to eq(:stripe_account_unavailable)
    expect(user.reload.active_bank_account).to be_nil
    expect(user.payment_address).to eq("paypal@example.com")
  end

  it "refuses when Stripe still has the account but has disabled payouts on it" do
    switch_to_paypal!
    stub_stripe_account(payouts_enabled: false, requirements: { disabled_reason: "rejected.fraud" })

    result = described_class.new(user:).process

    expect(result.error).to eq(:stripe_account_unavailable)
    expect(user.reload.active_bank_account).to be_nil
  end

  it "does not revive on top of a bank account saved while it waited for the lock" do
    switch_to_paypal!
    service = described_class.new(user:)
    allow(user).to receive(:with_lock).and_wrap_original do |original, &block|
      create(:indian_bank_account, user:, account_number: "000987654321", account_number_last_four: "4321")
      original.call(&block)
    end

    result = service.process

    expect(result.error).to eq(:bank_account_already_active)
    expect(user.bank_accounts.alive.count).to eq(1)
    expect(merchant_account.reload.deleted_at).to be_present
  end
end
