# frozen_string_literal: true

require "spec_helper"

# When a refund is rejected immediately because the party holding the money has an
# insufficient balance (bank-transfer methods like iDEAL/Bancontact fail instantly instead
# of queueing like cards), the seller-facing refund UI must show a message that names the
# actual holder of funds — Gumroad's platform balance, Stripe's held balance, or the
# creator's own connected account — so the seller knows whether waiting or contacting
# support is the right move.
describe "Refund insufficient-funds messaging", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Bancontact ebook", price_cents: 1900) }
  let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }
  let!(:purchase) do
    create(:purchase, link: product, seller:, full_name: "Customer 1",
                      email: "customer1@example.com", merchant_account:)
  end

  before do
    index_model_records(Purchase)
    allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)
    allow(ChargeProcessor).to receive(:refund!)
      .and_raise(ChargeProcessorInsufficientFundsError, "insufficient balance")
    login_as seller
  end

  def attempt_refund_expecting(message)
    visit customer_sale_path(purchase.external_id)
    expect(page).to have_text("Customer 1", wait: 15)
    click_on "Refund fully"
    within_modal "Purchase refund" do
      click_on "Confirm refund"
    end
    expect(page).to have_alert(text: message)
  end

  it "shows the Gumroad-held-funds message" do
    attempt_refund_expecting(Purchase::Refundable::INSUFFICIENT_FUNDS_GUMROAD_BALANCE_ERROR_MESSAGE)
  end

  context "when Stripe holds the funds" do
    let(:merchant_account) { create(:merchant_account, user: seller) }

    before do
      allow_any_instance_of(MerchantAccount).to receive(:holder_of_funds).and_return(HolderOfFunds::STRIPE)
    end

    it "shows the Stripe-held-funds message" do
      attempt_refund_expecting(Purchase::Refundable::INSUFFICIENT_FUNDS_STRIPE_BALANCE_ERROR_MESSAGE)
    end
  end

  context "when the creator's connected account holds the funds" do
    let(:merchant_account) { create(:merchant_account, user: seller) }

    before do
      allow_any_instance_of(MerchantAccount).to receive(:holder_of_funds).and_return(HolderOfFunds::CREATOR)
    end

    it "shows the connected-account message" do
      attempt_refund_expecting(Purchase::Refundable::INSUFFICIENT_FUNDS_CREATOR_STRIPE_BALANCE_ERROR_MESSAGE)
    end
  end
end
