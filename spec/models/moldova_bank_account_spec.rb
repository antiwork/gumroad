# frozen_string_literal: true

require "spec_helper"

describe MoldovaBankAccount do
  describe "#bank_account_type" do
    it "returns MD" do
      expect(create(:moldova_bank_account).bank_account_type).to eq("MD")
    end
  end

  describe "#country" do
    it "returns MD" do
      expect(create(:moldova_bank_account).country).to eq("MD")
    end
  end

  describe "#currency" do
    it "returns mdl" do
      expect(create(:moldova_bank_account).currency).to eq("mdl")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:moldova_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMDMDXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:moldova_bank_account, account_number_last_four: "5678").account_number_visual).to eq("******5678")
    end
  end

  describe "#validate_bank_code" do
    it "allows only 8-11 characters in the correct format" do
      expect(build(:moldova_bank_account, bank_code: "AAAAMDMDXXX")).to be_valid
      expect(build(:moldova_bank_account, bank_code: "BBBBMDMDYYY")).to be_valid
      expect(build(:moldova_bank_account, bank_code: "AGRNMD2XZZZ")).to be_valid
      expect(build(:moldova_bank_account, bank_code: "AGRNMD2ZZ")).not_to be_valid
      expect(build(:moldova_bank_account, bank_code: "AGRNMM2XZZZ")).not_to be_valid
      expect(build(:moldova_bank_account, bank_code: "AGRNMD2XZZZZ")).not_to be_valid
      expect(build(:moldova_bank_account, bank_code: "AAAMDMDXXX")).not_to be_valid
      expect(build(:moldova_bank_account, bank_code: "AAAAMDMDXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows only 24 characters in the correct format" do
      expect(build(:moldova_bank_account, account_number: "MD07AG123456789012345678")).to be_valid
      expect(build(:moldova_bank_account, account_number: "MD11BC987654321098765432")).to be_valid
      expect(build(:moldova_bank_account, account_number: "MD07AG12345678901234567")).not_to be_valid
      expect(build(:moldova_bank_account, account_number: "MD07AG1234567890123456789")).not_to be_valid
    end
  end
end
