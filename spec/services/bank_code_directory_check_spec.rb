# frozen_string_literal: true

require "spec_helper"

describe BankCodeDirectoryCheck do
  let(:user) { create(:named_user) }
  let(:bank_account) { build(:egypt_bank_account, user:, bank_code: "QNBAEGCX027") }

  def stripe_rejection(code: nil, param: nil, message: "We couldn't find the bank for that BIC")
    Stripe::InvalidRequestError.new(message, param, code:)
  end

  describe ".rejection_message_for" do
    it "tokenises the new details without creating anything and passes a resolvable code" do
      expect(Stripe::Token).to receive(:create).with(
        {
          bank_account: {
            country: "EG",
            currency: "egp",
            routing_number: "QNBAEGCX027",
            account_number: "EG800002000156789012345180002",
          },
        },
        hash_including(:client)
      ).and_return(double(bank_account: double(bank_name: "QATAR NATIONAL BANK S.A.E")))

      expect(described_class.rejection_message_for(bank_account)).to be_nil
    end

    it "names the 8-character code when Stripe cannot find the bank for a branch-suffixed BIC" do
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "routing_number_invalid", param: "bank_account[routing_number]"))

      expect(described_class.rejection_message_for(bank_account)).to eq(
        "Our payment partner couldn't find a bank for the bank code QNBAEGCX027. " \
        "Use the 8-character SWIFT/BIC code instead: QNBAEGCX rather than QNBAEGCX027."
      )
    end

    it "treats a rejection on the routing_number param as a directory miss even without a code" do
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(param: "bank_account[routing_number]"))

      expect(described_class.rejection_message_for(bank_account)).to include("QNBAEGCX rather than QNBAEGCX027")
    end

    it "asks the seller to check an 8-character code Stripe cannot resolve" do
      bank_account.bank_code = "ZZZZEGCX"
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "routing_number_invalid"))

      expect(described_class.rejection_message_for(bank_account)).to eq(
        "Our payment partner couldn't find a bank for the bank code ZZZZEGCX. " \
        "Please check it against the SWIFT/BIC code your bank publishes."
      )
    end

    it "fails open when Stripe rejects a different field" do
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "account_number_invalid", param: "bank_account[account_number]", message: "Invalid account number"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.rejection_message_for(bank_account)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/failed open.*Invalid account number/)
    end

    it "fails open on a connection error" do
      allow(Stripe::Token).to receive(:create).and_raise(Stripe::APIConnectionError.new("timed out"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.rejection_message_for(bank_account)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/failed open.*timed out/)
    end

    it "fails open on a rate limit" do
      allow(Stripe::Token).to receive(:create).and_raise(Stripe::RateLimitError.new("slow down"))

      expect(described_class.rejection_message_for(bank_account)).to be_nil
    end

    it "does not call Stripe for a country that is not opted in" do
      expect(Stripe::Token).not_to receive(:create)

      expect(described_class.rejection_message_for(build(:bahrain_bank_account, user:))).to be_nil
    end

    context "with the previous alive bank account" do
      it "skips the probe when the code is unchanged and already attached at Stripe" do
        previous = create(:egypt_bank_account, user:, bank_code: "QNBAEGCX027", stripe_bank_account_id: "ba_123")
        expect(Stripe::Token).not_to receive(:create)

        expect(described_class.rejection_message_for(bank_account, previous_bank_account: previous)).to be_nil
      end

      it "probes an unchanged code whose previous row never attached" do
        previous = create(:egypt_bank_account, user:, bank_code: "QNBAEGCX027", stripe_bank_account_id: nil)
        allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "routing_number_invalid"))

        expect(described_class.rejection_message_for(bank_account, previous_bank_account: previous)).to include("QNBAEGCX rather than")
      end

      it "probes when the code changed" do
        previous = create(:egypt_bank_account, user:, bank_code: "NBEGEGCX331", stripe_bank_account_id: "ba_123")
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_message_for(bank_account, previous_bank_account: previous)
      end

      it "probes when the previous row is for another country" do
        previous = create(:bahrain_bank_account, user:, stripe_bank_account_id: "ba_123")
        allow(previous).to receive(:stripe_external_account_routing_number).and_return("QNBAEGCX027")
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_message_for(bank_account, previous_bank_account: previous)
      end
    end
  end
end
