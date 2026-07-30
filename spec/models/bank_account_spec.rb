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

        it "notifies the error tracker" do
          expect(ErrorNotifier).to receive(:notify)
          bank_account.supports_instant_payouts?
        end
      end

      context "when stripe says the bank account has been deleted" do
        before do
          allow(Stripe::Account).to receive(:retrieve_external_account)
            .and_raise(Stripe::InvalidRequestError.new("The bank account ba_xxx has been deleted and can no longer be used.", "external_account"))
        end

        it "returns false" do
          expect(bank_account.supports_instant_payouts?).to be false
        end

        it "does not notify the error tracker" do
          expect(ErrorNotifier).not_to receive(:notify)
          bank_account.supports_instant_payouts?
        end
      end
    end
  end

  describe "#routing_field_descriptions" do
    it "names both halves for a country that collects a bank code and a branch code" do
      bank_account = build(:uzbekistan_bank_account, bank_code: "JSCLUZ22XXX", branch_code: "00401")

      expect(bank_account.routing_field_descriptions).to eq(["bank code JSCLUZ22XXX", "branch code 00401"])
    end

    it "uses the label the form shows rather than the underlying column name" do
      bank_account = build(:canadian_bank_account, institution_number: "003", transit_number: "12345")

      expect(bank_account.routing_field_descriptions).to eq(["transit number 12345", "institution number 003"])
    end

    it "describes an aliased column once, not under both names" do
      bank_account = build(:australian_bank_account, bsb_number: "062-111")

      expect(bank_account.routing_field_descriptions).to eq(["BSB 062-111"])
      expect(bank_account.routing_field_descriptions.count { |d| d.include?("062-111") }).to eq(1)
    end

    it "falls back to the routing number for a country that collects a single unlabelled value" do
      bank_account = build(:ach_account, routing_number: "110000000")

      expect(bank_account.routing_field_descriptions).to eq(["routing number 110000000"])
    end
  end

  describe "#has_separate_branch_code?" do
    it "is true when the seller filled in a bank code and a branch code" do
      expect(build(:uzbekistan_bank_account, bank_code: "JSCLUZ22XXX", branch_code: "00401")).to have_separate_branch_code
    end

    it "is false when the country collects one value" do
      expect(build(:ach_account)).not_to have_separate_branch_code
    end
  end
end
