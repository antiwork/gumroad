# frozen_string_literal: true

require "spec_helper"

describe RefundFundingChargeService do
  let(:user) { create(:user) }
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

  before do
    user.update!(refund_funding_credit_card: credit_card)
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    # Create Gumroad's merchant account (user: nil)
    MerchantAccount.find_or_create_by!(
      user_id: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ) { |ma| ma.charge_processor_merchant_id = "gumroad_stripe" }
  end

  describe "#perform" do
    context "when user has no refund funding credit card" do
      before do
        user.update!(refund_funding_credit_card: nil)
      end

      it "returns an error" do
        result = described_class.new(user: user, amount_cents: 1000).perform

        expect(result[:success]).to be false
        expect(result[:error]).to eq("No backup payment method configured.")
      end
    end

    context "when the charge succeeds" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test123",
            latest_charge: "ch_test123"
          )
        )
      end

      it "creates a credit for the user" do
        expect {
          described_class.new(user: user, amount_cents: 1000).perform
        }.to change(Credit, :count).by(1)
      end

      it "returns success" do
        result = described_class.new(user: user, amount_cents: 1000).perform

        expect(result[:success]).to be true
        expect(result[:payment_intent_id]).to eq("pi_test123")
      end

      it "creates a credit with the correct amount" do
        described_class.new(user: user, amount_cents: 1500).perform

        credit = Credit.last
        expect(credit.amount_cents).to eq(1500)
        expect(credit.user).to eq(user)
      end

      it "creates a balance transaction" do
        expect {
          described_class.new(user: user, amount_cents: 1000).perform
        }.to change(BalanceTransaction, :count).by(1)
      end

      it "adds a comment to the user" do
        expect {
          described_class.new(user: user, amount_cents: 1000).perform
        }.to change { user.comments.count }.by_at_least(1)

        expect(user.comments.any? { |c| c.content.include?("Balance topped up") }).to be true
      end
    end

    context "when the charge fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Your card was declined", nil, code: "card_declined")
        )
      end

      it "returns an error" do
        result = described_class.new(user: user, amount_cents: 1000).perform

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Your card was declined")
      end

      it "does not create a credit" do
        expect {
          described_class.new(user: user, amount_cents: 1000).perform
        }.not_to change(Credit, :count)
      end
    end

    context "when payment intent status is not succeeded" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "requires_action",
            id: "pi_test123"
          )
        )
      end

      it "returns an error" do
        result = described_class.new(user: user, amount_cents: 1000).perform

        expect(result[:success]).to be false
        expect(result[:error]).to include("Payment was not successful")
      end
    end

    context "when amount is below minimum" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test123",
            latest_charge: "ch_test123"
          )
        )
      end

      it "charges at least the minimum amount" do
        described_class.new(user: user, amount_cents: 10).perform

        expect(Stripe::PaymentIntent).to have_received(:create).with(
          hash_including(amount: RefundFundingChargeService::MINIMUM_CHARGE_CENTS),
          anything
        )
      end
    end

    context "when Stripe is unavailable" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::APIConnectionError.new("Could not connect to Stripe")
        )
      end

      it "returns a generic error" do
        result = described_class.new(user: user, amount_cents: 1000).perform

        expect(result[:success]).to be false
        expect(result[:error]).to include("Payment processor error")
      end
    end
  end
end
