# frozen_string_literal: true

require "spec_helper"

describe QatarBankAccount do
  describe "#bank_account_type" do
    it "returns QA" do
      expect(create(:qatar_bank_account).bank_account_type).to eq("QA")
    end
  end

  describe "#country" do
    it "returns QA" do
      expect(create(:qatar_bank_account).country).to eq("QA")
    end
  end

  describe "#currency" do
    it "returns qar" do
      expect(create(:qatar_bank_account).currency).to eq("qar")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:qatar_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAQAQAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:qatar_bank_account, account_number_last_four: "8901").account_number_visual).to eq("******8901")
    end
  end

  describe "#validate_bank_code" do
    it "allows 11 characters only" do
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXX")).to be_valid
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQA")).not_to be_valid
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows 29 characters only" do
      expect(build(:qatar_bank_account, account_number: "QA87CITI123456789012345678901")).to be_valid
      expect(build(:qatar_bank_account, account_number: "QA87CITI12345678901234567890")).not_to be_valid
      expect(build(:qatar_bank_account, account_number: "QA87CITI1234567890123456789012")).not_to be_valid
      expect(build(:qatar_bank_account, account_number: "1234567890")).not_to be_valid
      expect(build(:qatar_bank_account, account_number: "")).not_to be_valid
    end

    # Until this format check was fixed it only fired on a blank account number, so any
    # wrong-length value saved. Production holds 115 live Qatar accounts stored that way. They must
    # stay saveable: renaming the account holder and every `mark_deleted!` path (payout-method
    # switch, GDPR erasure, account closure) save the existing row, so validating the number on
    # update would make those sellers impossible to rename or delete.
    it "does not block saves of an already-stored account number that predates this format check" do
      bank_account = build(:qatar_bank_account, account_number: "1234567890")
      bank_account.save!(validate: false)

      bank_account.account_holder_full_name = "Renamed Seller"
      expect(bank_account.save).to be(true)
      expect { bank_account.mark_deleted! }.not_to raise_error
      expect(bank_account.reload.deleted_at).to be_present
    end
  end
end
