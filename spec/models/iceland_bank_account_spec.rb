# frozen_string_literal: true

require "spec_helper"

describe IcelandBankAccount do
  describe "#bank_account_type" do
    it "returns IS" do
      expect(create(:iceland_bank_account).bank_account_type).to eq("IS")
    end
  end

  describe "#country" do
    it "returns IS" do
      expect(create(:iceland_bank_account).country).to eq("IS")
    end
  end

  describe "#currency" do
    it "returns eur" do
      expect(create(:iceland_bank_account).currency).to eq("eur")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:iceland_bank_account, account_number_last_four: "0339").account_number_visual).to eq("IS******0339")
    end
  end

  describe "#validate_account_number" do
    it "validates the IBAN format" do
      expect(build(:iceland_bank_account)).to be_valid
      expect(build(:iceland_bank_account, account_number: "IS1401592600765455107303")).not_to be_valid
      expect(build(:iceland_bank_account, account_number: "IS14015926007654551073033911")).not_to be_valid
    end
  end
end
