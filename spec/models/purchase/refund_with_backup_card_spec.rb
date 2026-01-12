# frozen_string_literal: true

require "spec_helper"

describe "Purchase refund with backup card", type: :model do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:gumroad_merchant_account) do
    MerchantAccount.find_or_create_by!(
      user_id: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ) { |ma| ma.charge_processor_merchant_id = "gumroad_stripe" }
  end
  let(:credit_card) do
    CreditCard.new(
      stripe_customer_id: "cus_test123",
      processor_payment_method_id: "pm_test123",
      stripe_fingerprint: "fingerprint_123",
      visual: "Visa **** 4242",
      card_type: "visa",
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ).tap(&:save!)
  end
  let(:purchase) do
    create(:purchase,
           link: product,
           seller: seller,
           purchaser: buyer,
           price_cents: 2000,
           total_transaction_cents: 2000,
           succeeded_at: 1.day.ago,
           stripe_transaction_id: "ch_test123")
  end

  before do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    gumroad_merchant_account # Ensure merchant account exists
    allow(purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(true)
    # Create initial balance that's less than the refund amount
    create(:balance, user: seller, amount_cents: 500, merchant_account: gumroad_merchant_account)
  end

  context "when seller has no backup credit card" do
    context "and balance is insufficient" do
      it "fails with insufficient balance error" do
        result = purchase.refund_and_save!(nil)

        expect(result).to be false
        expect(purchase.errors[:base]).to include("Your balance is insufficient to process this refund.")
      end
    end

    context "and balance is sufficient" do
      before do
        create(:balance, user: seller, amount_cents: 2000, merchant_account: gumroad_merchant_account)
        allow(ChargeProcessor).to receive(:refund!).and_return(
          OpenStruct.new(id: "re_test123", refunded_amount_cents: 2000, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -2000))
        )
      end

      it "processes the refund successfully" do
        expect(purchase.refund_and_save!(nil)).to be_truthy
      end
    end
  end

  context "when seller has backup credit card configured" do
    before do
      seller.update!(refund_funding_credit_card: credit_card)
    end

    context "and card charge succeeds" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test123",
            latest_charge: "ch_test123"
          )
        )
        allow(ChargeProcessor).to receive(:refund!).and_return(
          OpenStruct.new(id: "re_test123", refunded_amount_cents: 2000, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -2000))
        )
      end

      it "charges the card for the shortfall and processes refund" do
        expect {
          purchase.refund_and_save!(nil)
        }.to change(Credit, :count).by_at_least(1)
      end

      it "calls Stripe with the correct shortfall amount" do
        purchase.refund_and_save!(nil)

        expect(Stripe::PaymentIntent).to have_received(:create).with(
          hash_including(amount: 1500), # 2000 - 500 = 1500 shortfall
          anything
        )
      end
    end

    context "and card charge fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Card declined", nil, code: "card_declined")
        )
      end

      it "fails the refund with card error" do
        result = purchase.refund_and_save!(nil)

        expect(result).to be false
        expect(purchase.errors[:base].first).to include("Card declined")
      end

      it "does not process the refund" do
        expect(ChargeProcessor).not_to receive(:refund!)

        purchase.refund_and_save!(nil)
      end
    end
  end
end
