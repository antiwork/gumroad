# frozen_string_literal: true

require "spec_helper"

RSpec.describe Payment, type: :model do
  describe "#displayable_failure_reason" do
    let(:user) { create(:user) }

    it "returns curated PayPal reason when available" do
      payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
      payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 11711")
      expect(payment.displayable_failure_reason).to eq("per-transaction sending limit exceeded")
    end

    it "falls back to PayPal mass pay map when curated not available" do
      payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
      payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 1001")
      expect(payment.displayable_failure_reason).to eq("Receiver's account is invalid")
    end

    it "returns Stripe curated reason when available" do
      payment = create(:payment, user:, processor: PayoutProcessorType::STRIPE)
      payment.update!(state: Payment::FAILED, failure_reason: "account_closed")
      expect(payment.displayable_failure_reason).to eq("the bank account has been closed")
    end

    it "humanizes unknown Stripe reason" do
      payment = create(:payment, user:, processor: PayoutProcessorType::STRIPE)
      payment.update!(state: Payment::FAILED, failure_reason: "some_new_code")
      expect(payment.displayable_failure_reason).to eq("some new code")
    end
  end

  describe "#requires_verification_to_resume?" do
    let(:user) { create(:user) }

    context "when PayPal regulatory review codes" do
      it "returns true for PAYPAL 14763 (Pending)" do
        payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
        payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 14763")
        expect(payment.requires_verification_to_resume?).to be true
      end

      it "returns true for PAYPAL 14764 (Blocked)" do
        payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
        payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 14764")
        expect(payment.requires_verification_to_resume?).to be true
      end
    end

    context "when other PayPal codes" do
      it "returns false for non-regulatory code (e.g., 11711)" do
        payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
        payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 11711")
        expect(payment.requires_verification_to_resume?).to be false
      end

      it "returns the raw code as reason if not curated nor in mass pay map" do
        payment = create(:payment, user:, processor: PayoutProcessorType::PAYPAL)
        payment.update!(state: Payment::FAILED, failure_reason: "PAYPAL 99999")
        expect(payment.displayable_failure_reason).to eq("PAYPAL 99999")
        expect(payment.requires_verification_to_resume?).to be false
      end
    end

    context "when Stripe" do
      it "returns false for Stripe codes (handled outside failed payouts)" do
        payment = create(:payment, user:, processor: PayoutProcessorType::STRIPE)
        payment.update!(state: Payment::FAILED, failure_reason: "account_closed")
        expect(payment.requires_verification_to_resume?).to be false
      end
    end
  end
end


