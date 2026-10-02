# frozen_string_literal: true

require "spec_helper"

describe Purchase, "charging on a replaced managed account" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_managed_replaced") }
  let(:purchase) { create(:purchase, link: product, seller:, merchant_account:, purchase_state: "in_progress") }

  before do
    merchant_account.delete_charge_processor_account!
    purchase.merchant_account = MerchantAccount.find(merchant_account.id)
  end

  it "fails the purchase with a retry message and creates no charge" do
    expect(Stripe::PaymentIntent).not_to receive(:create)

    expect(purchase.send(:create_charge_intent, instance_double(Chargeable))).to be_nil

    expect(purchase.errors.full_messages).to include(a_string_including("your card was not charged"))
    expect(purchase.stripe_error_code).to eq(MerchantAccount::REPLACED_ACCOUNT_ERROR_CODE)
    expect(purchase.reload.processor_payment_intent).to be_nil
    expect(BalanceTransaction.where(user: seller)).to be_empty
  end

  it "is a retryable error, so a renewal is rescheduled instead of reported as a declined card" do
    purchase.send(:create_charge_intent, instance_double(Chargeable))

    expect(purchase.has_payment_network_error?).to be(true)
  end
end
