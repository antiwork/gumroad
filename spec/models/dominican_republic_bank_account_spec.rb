# frozen_string_literal: true

require "spec_helper"

describe DominicanRepublicBankAccount do
  let(:bank_account) { build(:dominican_republic_bank_account) }

  describe "#bank_account_type" do
    it "returns DO" do
      expect(bank_account.bank_account_type).to eq("DO")
    end
  end

  describe "#country" do
    it "returns DO" do
      expect(bank_account.country).to eq("DO")
    end
  end

  describe "#currency" do
    it "returns dop" do
      expect(bank_account.currency).to eq("dop")
    end
  end

  describe "#routing_number" do
    it "returns the bank code" do
      expect(bank_account.routing_number).to eq(bank_account.bank_code)
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(bank_account.account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 1 to 3 digits only" do
      expect(build(:dominican_republic_bank_account, bank_code: "1")).to be_valid
      expect(build(:dominican_republic_bank_account, bank_code: "12")).to be_valid
      expect(build(:dominican_republic_bank_account, bank_code: "123")).to be_valid
      expect(build(:dominican_republic_bank_account, bank_code: "1234")).not_to be_valid
      expect(build(:dominican_republic_bank_account, bank_code: "a12")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "validates the account number format" do
      expect(bank_account).to be_valid

      bank_account.account_number = "invalid123"
      expect(bank_account).not_to be_valid
      expect(bank_account.errors[:base]).to include("The account number is invalid.")

      bank_account.account_number = "12345678901234567890123456789" # 29 digits
      expect(bank_account).not_to be_valid
      expect(bank_account.errors[:base]).to include("The account number is invalid.")

      bank_account.account_number = "1234567890123456789012345678" # 28 digits
      expect(bank_account).to be_valid
    end
  end
end
