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
    # Gumroad's platform merchant account must exist for credits
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    seller.update!(refund_funding_credit_card: credit_card)
  end

  describe "#perform" do
    subject(:result) { described_class.new(user: seller, amount_cents: amount_cents, purchase: purchase).perform }

    let(:amount_cents) { 1500 }

    context "when credit card is not configured" do
      before do
        seller.update!(refund_funding_credit_card: nil)
      end

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

      it "returns success" do
        expect(result.success?).to be true
        expect(result.error_message).to be_nil
      end

      it "creates a credit" do
        expect { result }.to change(Credit, :count).by(1)
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

      it "returns the credit" do
        expect(result.credit).to be_a(Credit)
        expect(result.credit.amount_cents).to eq(1500)
      end

      it "sends a confirmation email" do
        expect(ContactingCreatorMailer).to receive(:refund_funding_charge_confirmation)
          .with(credit_id: instance_of(Integer))
          .and_return(double(deliver_later: true))

        result
      end

      it "calls Stripe with correct parameters" do
        expect(Stripe::PaymentIntent).to receive(:create).with(
          hash_including(
            amount: 1500,
            currency: "usd",
            customer: credit_card.stripe_customer_id,
            payment_method: credit_card.processor_payment_method_id,
            off_session: true,
            confirm: true,
            description: "Gumroad refund funding charge",
            metadata: hash_including(
              user_id: seller.id,
              user_email: seller.email,
              purchase_id: purchase.id,
              type: "refund_funding"
            )
          ),
          hash_including(:idempotency_key)
        ).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )

        result
      end
    end

    context "when Stripe charge fails with card error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Your card was declined.", nil, code: "card_declined")
        )
      end

      it "returns failure with error message" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Your card was declined.")
      end

      it "does not create a credit" do
        expect { result }.not_to change(Credit, :count)
      end
    end

    context "when Stripe returns invalid request error" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new("Invalid customer", nil)
        )
      end

      it "returns failure with generic error message" do
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

      it "returns failure with payment processor error message" do
        expect(result.success?).to be false
        expect(result.error_message).to eq("Payment processor error. Please try again.")
      end
    end

    context "when payment intent status is not succeeded" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "requires_action",
            id: "pi_test_123",
            latest_charge: nil
          )
        )
      end

      it "returns failure" do
        expect(result.success?).to be false
        expect(result.error_message).to include("Payment was not successful")
      end

      it "does not create a credit" do
        expect { result }.not_to change(Credit, :count)
      end
    end

    context "when email sending fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
        allow(ContactingCreatorMailer).to receive(:refund_funding_charge_confirmation)
          .and_raise(StandardError.new("SMTP error"))
      end

      it "still returns success" do
        expect(result.success?).to be true
      end

      it "still creates the credit" do
        expect { result }.to change(Credit, :count).by(1)
      end
    end
  end

  describe "constants" do
    it "has minimum charge of $1.00" do
      expect(described_class::MINIMUM_CHARGE_CENTS).to eq(100)
    end

    it "has maximum charge of $10,000" do
      expect(described_class::MAXIMUM_CHARGE_CENTS).to eq(1_000_000)
    end
  end
end
