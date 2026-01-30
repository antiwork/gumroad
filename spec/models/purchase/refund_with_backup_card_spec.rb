# frozen_string_literal: true

require "spec_helper"

describe "Refund with backup card", type: :model do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:credit_card) do
    CreditCard.new(
      stripe_customer_id: "cus_test_123",
      processor_payment_method_id: "pm_test_123",
      stripe_fingerprint: "fingerprint_123",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ).tap(&:save!)
  end
  let(:purchase) do
    create(:purchase_in_progress,
           link: product,
           seller:,
           purchaser: buyer,
           price_cents: 2000,
           total_transaction_cents: 2000).tap do |p|
      p.update_columns(succeeded_at: 1.day.ago, purchase_state: "successful")
    end
  end

  def build_charge_refund_mock(amount_cents)
    flow_of_funds = FlowOfFunds.new(
      issued_amount: FlowOfFunds::Amount.new(currency: "usd", cents: -amount_cents),
      settled_amount: FlowOfFunds::Amount.new(currency: "usd", cents: -amount_cents),
      gumroad_amount: FlowOfFunds::Amount.new(currency: "usd", cents: 0),
      merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: "usd", cents: -amount_cents),
      merchant_account_net_amount: FlowOfFunds::Amount.new(currency: "usd", cents: -amount_cents)
    )
    stripe_refund = double("StripeRefund", id: "re_test_123", status: "succeeded")
    double("ChargeRefund", id: "re_test_123", flow_of_funds: flow_of_funds, status: "succeeded", refund: stripe_refund)
  end

  before do
    # Gumroad's platform merchant account must exist for credits
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    allow(purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(true)
    create(:balance, user: seller, amount_cents: 500, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
  end

  context "when seller has no refund funding credit card" do
    context "when balance is insufficient" do
      it "fails with insufficient balance error" do
        result = purchase.refund_and_save!(nil)

        expect(result).to be false
        expect(purchase.errors[:base]).to include("Your balance is insufficient to process this refund.")
      end
    end

    context "when balance is sufficient" do
      before do
        create(:balance, user: seller, amount_cents: 2000, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
        allow(ChargeProcessor).to receive(:refund!).and_return(build_charge_refund_mock(2000))
      end

      it "processes the refund successfully" do
        expect(purchase.refund_and_save!(nil)).to be true
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
        allow(ChargeProcessor).to receive(:refund!).and_return(build_charge_refund_mock(2000))
      end

      it "charges the credit card for the shortfall and creates a credit" do
        expect {
          purchase.refund_and_save!(nil)
        }.to change { Credit.where.not(refund_funding_purchase_id: nil).count }.by(1)

        credit = Credit.find_by(refund_funding_purchase: purchase)
        expect(credit.amount_cents).to eq(1500) # 2000 - 500 = 1500 shortfall
        expect(credit.refund_funding_purchase).to eq(purchase)
        expect(credit.credit_card).to eq(credit_card)
        expect(credit.refund_funding_processor_transaction_id).to eq("ch_test_123")
        expect(credit.refund_funding_processor_payment_intent_id).to eq("pi_test_123")
      end

      it "updates the seller balance" do
        expect {
          purchase.refund_and_save!(nil)
        }.to change { seller.reload.unpaid_balance_cents }

        # Balance should have the credit amount added
        credit = Credit.find_by(refund_funding_purchase: purchase)
        expect(credit.balance).to be_present
      end

      it "processes the refund successfully" do
        expect(purchase.refund_and_save!(nil)).to be true
        expect(purchase.stripe_refunded?).to be true
      end
    end

    context "when shortfall is less than minimum charge" do
      before do
        # Seller has $19.50, purchase is $20, shortfall is $0.50 which is below $1 minimum
        create(:balance, user: seller, amount_cents: 1450, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
        allow(ChargeProcessor).to receive(:refund!).and_return(build_charge_refund_mock(2000))
      end

      it "charges the minimum amount of $1.00" do
        purchase.refund_and_save!(nil)

        credit = Credit.find_by(refund_funding_purchase: purchase)
        expect(credit.amount_cents).to eq(100) # Minimum charge is $1.00
      end
    end

    context "when card charge fails" do
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

      it "does not create a credit" do
        expect {
          purchase.refund_and_save!(nil)
        }.not_to change(Credit, :count)
      end
    end

    context "when Stripe returns a non-card error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::StripeError.new("Network error")
        )
      end

      it "fails with a generic error message" do
        result = purchase.refund_and_save!(nil)

        expect(result).to be false
        expect(purchase.errors[:base].first).to include("Payment processor error")
      end
    end
  end
end
