# frozen_string_literal: true

require "spec_helper"

describe BalanceTopUp::ChargeService, :vcr do
  let(:user) { create(:user) }
  let(:credit_card) { create(:credit_card) }

  before do
    user.update!(refund_funding_credit_card: credit_card)
  end

  describe "#perform" do
    context "when no credit card is configured" do
      before do
        user.update!(refund_funding_credit_card: nil)
      end

      it "returns error" do
        result = described_class.new(user:, amount_cents: 1000).perform

        expect(result.success?).to be false
        expect(result.error_message).to eq("No credit card configured for balance funding.")
      end
    end

    context "when amount is below minimum" do
      it "returns error" do
        result = described_class.new(user:, amount_cents: 50).perform

        expect(result.success?).to be false
        expect(result.error_message).to include("at least")
      end
    end

    context "when amount exceeds maximum" do
      it "returns error" do
        result = described_class.new(user:, amount_cents: 2_000_000).perform

        expect(result.success?).to be false
        expect(result.error_message).to include("cannot exceed")
      end
    end

    context "when card charge succeeds", :vcr do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
      end

      it "creates a successful balance top-up" do
        result = described_class.new(user:, amount_cents: 1000).perform

        expect(result.success?).to be true
        expect(result.balance_top_up).to be_successful
        expect(result.balance_top_up.amount_cents).to eq(1000)
        expect(result.balance_top_up.processor_payment_intent_id).to eq("pi_test_123")
        expect(result.balance_top_up.processor_transaction_id).to eq("ch_test_123")
      end

      it "creates a credit for the user" do
        expect {
          described_class.new(user:, amount_cents: 1000).perform
        }.to change(Credit, :count).by(1)

        credit = Credit.last
        expect(credit.user).to eq(user)
        expect(credit.amount_cents).to eq(1000)
        expect(credit.balance_top_up).to be_present
      end

      it "increases the user's balance" do
        initial_balance = user.unpaid_balance_cents

        described_class.new(user:, amount_cents: 1000).perform

        expect(user.reload.unpaid_balance_cents).to eq(initial_balance + 1000)
      end

      it "enqueues a notification job" do
        expect(BalanceTopUpNotificationJob).to receive(:perform_async)

        described_class.new(user:, amount_cents: 1000).perform
      end
    end

    context "when card charge fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Your card was declined.", nil, code: "card_declined")
        )
      end

      it "returns error with message" do
        result = described_class.new(user:, amount_cents: 1000).perform

        expect(result.success?).to be false
        expect(result.error_message).to eq("Your card was declined.")
      end

      it "marks the balance top-up as failed" do
        result = described_class.new(user:, amount_cents: 1000).perform

        expect(result.balance_top_up).to be_failed
        expect(result.balance_top_up.error_message).to eq("Your card was declined.")
      end

      it "does not create a credit" do
        expect {
          described_class.new(user:, amount_cents: 1000).perform
        }.not_to change(Credit, :count)
      end
    end

    context "when Stripe returns an unexpected status" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(status: "requires_action", id: "pi_test_123")
        )
      end

      it "returns error" do
        result = described_class.new(user:, amount_cents: 1000).perform

        expect(result.success?).to be false
        expect(result.error_message).to include("requires_action")
      end
    end

    context "when a purchase is associated" do
      let(:purchase) { create(:purchase, seller: user) }

      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(
          OpenStruct.new(
            status: "succeeded",
            id: "pi_test_123",
            latest_charge: "ch_test_123"
          )
        )
      end

      it "links the balance top-up to the purchase" do
        result = described_class.new(user:, amount_cents: 1000, purchase:).perform

        expect(result.balance_top_up.purchase).to eq(purchase)
      end
    end
  end
end
