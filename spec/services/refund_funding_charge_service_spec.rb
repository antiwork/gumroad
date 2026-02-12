# frozen_string_literal: true

require "spec_helper"

describe RefundFundingChargeService do
  let(:seller) { create(:user) }
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
        expect(result.error_message).to eq("Amount must be at least $1.")
      end
    end

    context "when amount exceeds maximum" do
      let(:amount_cents) { 1_500_000 }

      it "returns an error" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Amount cannot exceed $10,000.")
      end
    end

    context "when Stripe charge succeeds" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
      end

      it "returns success with a credit" do
        expect(result.success?).to be true
        expect(result.error_message).to be_nil
        expect(result.credit).to be_a(Credit)
        expect(result.credit.amount_cents).to eq(1500)
      end

      it "creates a credit with correct attributes" do
        result
        credit = Credit.last
        expect(credit.user).to eq(seller)
        expect(credit.amount_cents).to eq(1500)
        expect(credit.refund_funding_purchase).to eq(purchase)
        expect(credit.credit_card).to eq(credit_card)
        expect(credit.refund_funding_processor_transaction_id).to eq("ch_test_123")
        expect(credit.refund_funding_processor_payment_intent_id).to eq("pi_test_123")
      end

      it "creates a balance transaction" do
        expect { result }.to change(BalanceTransaction, :count).by(1)
        balance_transaction = BalanceTransaction.last
        expect(balance_transaction.user).to eq(seller)
        expect(balance_transaction.issued_amount_gross_cents).to eq(1500)
      end

      it "calls Stripe with deterministic idempotency key" do
        expect(Stripe::PaymentIntent).to receive(:create).with(
          hash_including(
            amount: 1500,
            currency: "usd",
            customer: "cus_test_123",
            payment_method: "pm_test_123",
            off_session: true,
            confirm: true
          ),
          { idempotency_key: "refund_funding_#{seller.id}_#{purchase.id}" }
        ).and_return(
          OpenStruct.new(status: "succeeded", id: "pi_test_123", latest_charge: "ch_test_123")
        )
        result
      end
    end

    context "when Stripe returns requires_action (3D Secure)" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(status: "requires_action", id: "pi_test_123", latest_charge: nil)
        )
      end

      it "returns failure with SCA-specific message" do
        expect(result.success?).to be false
        expect(result.error_message).to include("additional authentication")
        expect { result }.not_to change(Credit, :count)
      end
    end

    context "when Stripe card error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Your card was declined.", nil, code: "card_declined")
        )
      end

      it "returns failure with card error message" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Your card was declined.")
        expect { result }.not_to change(Credit, :count)
      end
    end

    context "when Stripe generic error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::StripeError.new("Network timeout")
        )
      end

      it "returns failure with generic message" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Payment processor error. Please try again.")
      end
    end
  end

  describe "#reverse_charge!" do
    let(:service) { described_class.new(user: seller, amount_cents: 1500, purchase:) }

    it "creates a Stripe refund for the payment intent" do
      expect(Stripe::Refund).to receive(:create).with({ payment_intent: "pi_test_123" })
      service.reverse_charge!("pi_test_123")
    end

    it "handles Stripe errors gracefully" do
      allow(Stripe::Refund).to receive(:create).and_raise(Stripe::StripeError.new("Refund failed"))
      expect { service.reverse_charge!("pi_test_123") }.not_to raise_error
    end
  end
end
