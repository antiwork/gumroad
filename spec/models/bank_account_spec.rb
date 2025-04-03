# frozen_string_literal: true

require "spec_helper"

describe BankAccount do
  describe "routing_number" do
    let(:australian_bank_account) { build(:australian_bank_account) }

    it "returns the decrypted account number" do
      expect(australian_bank_account.send(:account_number_decrypted)).to eq("1234567")
    end
  end

  describe "#supports_instant_payouts?" do
    let(:bank_account) { create(:ach_account) }

    context "when stripe connect and external account IDs are not present" do
      it "returns false" do
        expect(bank_account.supports_instant_payouts?).to be false
      end
    end

    context "when stripe connect and external account IDs are present" do
      before do
        bank_account.update!(
          stripe_connect_account_id: "acct_123",
          stripe_external_account_id: "ba_456"
        )
      end

      context "when external account supports instant payouts" do
        before do
          external_account = double(available_payout_methods: ["instant"])
          allow(Stripe::Account).to receive(:retrieve_external_account)
            .with("acct_123", "ba_456")
            .and_return(external_account)
        end

        it "returns true" do
          expect(bank_account.supports_instant_payouts?).to be true
        end
      end

      context "when external account does not support instant payouts" do
        before do
          external_account = double(available_payout_methods: ["standard"])
          allow(Stripe::Account).to receive(:retrieve_external_account)
            .with("acct_123", "ba_456")
            .and_return(external_account)
        end

        it "returns false" do
          expect(bank_account.supports_instant_payouts?).to be false
        end
      end

      context "when stripe API call fails" do
        before do
          allow(Stripe::Account).to receive(:retrieve_external_account)
            .and_raise(Stripe::StripeError.new)
        end

        it "returns false" do
          expect(bank_account.supports_instant_payouts?).to be false
        end
      end
    end
  end
end
