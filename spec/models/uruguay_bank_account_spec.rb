# frozen_string_literal: true

require "spec_helper"

describe UruguayBankAccount do
  describe "#bank_account_type" do
    it "returns UY" do
      expect(create(:uruguay_bank_account).bank_account_type).to eq("UY")
    end
  end

  describe "#country" do
    it "returns UY" do
      expect(create(:uruguay_bank_account).country).to eq("UY")
    end
  end

  describe "#currency" do
    it "returns uyu" do
      expect(create(:uruguay_bank_account).currency).to eq(Currency::UYU)
    end
  end

  describe "#bank_code" do
    it "returns valid for 3 digits" do
      expect(build(:uruguay_bank_account, bank_number: "123")).to be_valid
      expect(build(:uruguay_bank_account, bank_number: "12")).not_to be_valid
      expect(build(:uruguay_bank_account, bank_number: "1234")).not_to be_valid
      expect(build(:uruguay_bank_account, bank_number: "abc")).not_to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:uruguay_bank_account).account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows 1 to 18 digits" do
      expect(build(:uruguay_bank_account, account_number: "1")).to be_valid
      expect(build(:uruguay_bank_account, account_number: "123456789101")).to be_valid
      expect(build(:uruguay_bank_account, account_number: "1234567891011")).not_to be_valid
      expect(build(:uruguay_bank_account, account_number: "abc")).not_to be_valid
    end
  end
end
