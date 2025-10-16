# frozen_string_literal: true

require "spec_helper"

RSpec.describe ChargeSellerRefundCardService do
  let(:seller) { create(:user) }
  let(:refund_amount_cents) { 1000 }
  let(:service) { described_class.new(seller, refund_amount_cents) }

  describe "#call" do
    context "when seller has no refund credit card" do
      it "returns failure with appropriate message" do
        result = service.call

        expect(result.success?).to be false
        expect(result.error_message).to eq("Seller has no refund credit card set")
        expect(result.charged_amount).to eq(0)
      end
    end

    context "when seller has refund credit card" do
      let(:refund_credit_card) { create(:credit_card, stripe_customer_id: "cus_123", stripe_card_id: "card_123") }

      before do
        seller.update!(refund_credit_card: refund_credit_card)
      end

      context "when seller has sufficient balance" do
        before do
          allow(seller).to receive(:unpaid_balance_cents).and_return(1500)
        end

        it "returns success without charging" do
          result = service.call

          expect(result.success?).to be true
          expect(result.error_message).to be_nil
          expect(result.charged_amount).to eq(0)
        end

        it "does not call Stripe" do
          expect(Stripe::Charge).not_to receive(:create)
          service.call
        end
      end

      context "when seller has insufficient balance" do
        before do
          allow(seller).to receive(:unpaid_balance_cents).and_return(500)
        end

        context "when Stripe charge succeeds" do
          let(:stripe_charge) { double("Stripe::Charge", status: "succeeded", id: "ch_123") }

          before do
            allow(Stripe::Charge).to receive(:create).and_return(stripe_charge)
          end

          it "charges the difference amount" do
            expect(Stripe::Charge).to receive(:create).with(
              amount: 500,
              currency: "usd",
              customer: "cus_123",
              source: "card_123",
              description: "Refund payment method charge for seller #{seller.id}"
            )

            result = service.call

            expect(result.success?).to be true
            expect(result.charged_amount).to eq(500)
          end
        end

        context "when Stripe charge fails" do
          let(:stripe_charge) { double("Stripe::Charge", status: "failed", failure_message: "Your card was declined.") }

          before do
            allow(Stripe::Charge).to receive(:create).and_return(stripe_charge)
          end

          it "returns failure with Stripe error message" do
            result = service.call

            expect(result.success?).to be false
            expect(result.error_message).to eq("Stripe charge failed: Your card was declined.")
            expect(result.charged_amount).to eq(0)
          end
        end

        context "when Stripe raises an error" do
          before do
            allow(Stripe::Charge).to receive(:create).and_raise(Stripe::CardError.new("Your card has insufficient funds.", "card_declined"))
          end

          it "returns failure with Stripe error message" do
            result = service.call

            expect(result.success?).to be false
            expect(result.error_message).to eq("Stripe error: Your card has insufficient funds.")
            expect(result.charged_amount).to eq(0)
          end
        end

        context "when an unexpected error occurs" do
          before do
            allow(Stripe::Charge).to receive(:create).and_raise(StandardError.new("Network timeout"))
          end

          it "returns failure with error message" do
            result = service.call

            expect(result.success?).to be false
            expect(result.error_message).to eq("Unexpected error: Network timeout")
            expect(result.charged_amount).to eq(0)
          end
        end
      end

      context "when seller has exact balance needed" do
        before do
          allow(seller).to receive(:unpaid_balance_cents).and_return(1000) # Exactly $10.00
        end

        it "returns success without charging" do
          result = service.call

          expect(result.success?).to be true
          expect(result.error_message).to be_nil
          expect(result.charged_amount).to eq(0)
        end

        it "does not call Stripe" do
          expect(Stripe::Charge).not_to receive(:create)
          service.call
        end
      end
    end
  end

  describe "#success?" do
    it "returns true when no error message is set" do
      service.instance_variable_set(:@error_message, nil)
      expect(service.success?).to be true
    end

    it "returns false when error message is set" do
      service.instance_variable_set(:@error_message, "Some error")
      expect(service.success?).to be false
    end
  end

  describe "#charged_amount" do
    it "returns 0 when no charge was made" do
      expect(service.charged_amount).to eq(0)
    end

    it "returns the charged amount when set" do
      service.instance_variable_set(:@charged_amount, 500)
      expect(service.charged_amount).to eq(500)
    end
  end
end
