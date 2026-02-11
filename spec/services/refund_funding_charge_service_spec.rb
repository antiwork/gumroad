# frozen_string_literal: true

require "spec_helper"

describe RefundFundingChargeService, :vcr do
  let(:seller) { create(:user) }
  let(:credit_card) { create(:credit_card, user: seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(:purchase_in_progress,
           link: product,
           seller:,
           price_cents: 2000,
           total_transaction_cents: 2000).tap do |p|
      p.update_columns(succeeded_at: 1.day.ago, purchase_state: "successful")
    end
  end

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    seller.update!(refund_funding_credit_card: credit_card)
  end

  describe "#perform" do
    subject(:result) { described_class.new(user: seller, amount_cents:, purchase:).perform }

    let(:amount_cents) { 1500 }

    context "when credit card is not configured" do
      before { seller.update!(refund_funding_credit_card: nil) }

      it "returns an error" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("No backup payment method configured.")
      end
    end

    context "when amount is below minimum" do
      let(:amount_cents) { 50 }

      it "returns an error" do
        expect(result.success?).to be false
        expect(result.error_message).to include("at least")
      end
    end

    context "when amount exceeds maximum" do
      let(:amount_cents) { 1_500_000 }

      it "returns an error" do
        expect(result.success?).to be false
        expect(result.error_message).to include("cannot exceed")
      end
    end

    context "when Stripe charge succeeds" do
      let(:payment_intent_double) do
        Struct.new(:status, :id, :latest_charge, keyword_init: true).new(
          status: "succeeded",
          id: "pi_test_123",
          latest_charge: "ch_test_123"
        )
      end

      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(payment_intent_double)
      end

      it "returns success with credit and calls Stripe correctly" do
        expect(Stripe::PaymentIntent).to receive(:create).with(
          hash_including(
            amount: 1500,
            currency: Currency::USD,
            customer: credit_card.stripe_customer_id,
            payment_method: credit_card.processor_payment_method_id,
            off_session: true,
            confirm: true
          ),
          hash_including(:idempotency_key)
        ).and_return(payment_intent_double)

        expect { result }.to change(Credit, :count).by(1)
          .and change(BalanceTransaction, :count).by(1)

        expect(result.success?).to be true
        expect(result.error_message).to be_nil
        expect(result.payment_intent_id).to eq("pi_test_123")

        credit = result.credit
        expect(credit.user).to eq(seller)
        expect(credit.amount_cents).to eq(1500)
        expect(credit.refund_funding_purchase).to eq(purchase)
        expect(credit.credit_card).to eq(credit_card)
        expect(credit.refund_funding_processor_transaction_id).to eq("ch_test_123")
        expect(credit.refund_funding_processor_payment_intent_id).to eq("pi_test_123")
        expect(credit.balance).to be_present
      end
    end

    context "when Stripe charge fails with card error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Your card was declined.", nil, code: "card_declined")
        )
      end

      it "returns failure without creating a credit" do
        expect { result }.not_to change(Credit, :count)
        expect(result.success?).to be false
        expect(result.error_message).to eq("Your card was declined.")
      end
    end

    context "when Stripe returns invalid request error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new("Invalid customer", nil)
        )
      end

      it "returns failure with generic error" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Invalid payment request.")
      end
    end

    context "when Stripe returns generic error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::StripeError.new("Network timeout")
        )
      end

      it "returns failure with payment processor error" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Payment processor error. Please try again.")
      end
    end

    context "when payment intent requires 3D Secure" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          Struct.new(:status, :id, :latest_charge, keyword_init: true).new(
            status: "requires_action",
            id: "pi_test_123",
            latest_charge: nil
          )
        )
      end

      it "returns failure with SCA message and does not create a credit" do
        expect { result }.not_to change(Credit, :count)
        expect(result.success?).to be false
        expect(result.error_message).to include("3D Secure")
      end
    end
  end

  describe ".reverse_charge!" do
    it "creates a Stripe refund for the payment intent" do
      expect(Stripe::Refund).to receive(:create).with({ payment_intent: "pi_test_123" })

      described_class.reverse_charge!(payment_intent_id: "pi_test_123")
    end

    it "logs and reports errors without raising" do
      allow(Stripe::Refund).to receive(:create).and_raise(Stripe::StripeError.new("Network error"))
      expect(Bugsnag).to receive(:notify)

      expect { described_class.reverse_charge!(payment_intent_id: "pi_test_123") }.not_to raise_error
    end
  end
end
