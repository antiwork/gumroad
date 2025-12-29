# frozen_string_literal: true

require "spec_helper"

describe "Refund with balance top-up", :vcr, type: :model do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:credit_card) { create(:credit_card) }
  let(:purchase) do
    create(:purchase,
           :successful,
           :with_charge,
           link: product,
           seller:,
           purchaser: buyer,
           price_cents: 2000,
           total_transaction_cents: 2000)
  end

  before do
    allow(purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(true)
    create(:balance, user: seller, amount_cents: 500, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
  end

  context "when seller has no refund funding credit card" do
    context "when balance is insufficient" do
      it "fails with insufficient balance error" do
        result = purchase.refund_and_save!

        expect(result).to be false
        expect(purchase.errors[:base]).to include("Your balance is insufficient to process this refund.")
      end
    end

    context "when balance is sufficient" do
      before do
        create(:balance, user: seller, amount_cents: 2000, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
        allow(ChargeProcessor).to receive(:refund!).and_return(
          OpenStruct.new(id: "re_test_123", refunded_amount_cents: 2000)
        )
      end

      it "processes the refund successfully" do
        expect(purchase.refund_and_save!).to be true
      end
    end
  end

  context "when seller has refund funding credit card configured" do
    before do
      seller.update!(refund_funding_credit_card: credit_card)
    end

    context "when card charge succeeds" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
        allow(ChargeProcessor).to receive(:refund!).and_return(
          OpenStruct.new(id: "re_test_123", refunded_amount_cents: 2000)
        )
      end

      it "charges the credit card for the shortfall and processes refund" do
        expect {
          purchase.refund_and_save!
        }.to change(BalanceTopUp, :count).by(1)

        balance_top_up = BalanceTopUp.last
        expect(balance_top_up.amount_cents).to eq(1500) # 2000 - 500 = 1500 shortfall
        expect(balance_top_up).to be_successful
      end

      it "creates a credit for the seller" do
        expect {
          purchase.refund_and_save!
        }.to change(Credit, :count)
      end
    end

    context "when card charge fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Card declined", nil, code: "card_declined")
        )
      end

      it "fails the refund with card error" do
        result = purchase.refund_and_save!

        expect(result).to be false
        expect(purchase.errors[:base].first).to include("Card declined")
      end

      it "does not process the refund" do
        expect(ChargeProcessor).not_to receive(:refund!)

        purchase.refund_and_save!
      end
    end
  end
end
