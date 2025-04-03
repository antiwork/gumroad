# frozen_string_literal: true

require "spec_helper"

describe BoliviaBankAccount do
  describe "#bank_account_type" do
    it "returns BO" do
      expect(create(:bolivia_bank_account).bank_account_type).to eq("BO")
    end
  end

  describe "#country" do
    it "returns BO" do
      expect(create(:bolivia_bank_account).country).to eq("BO")
    end
  end

  describe "#currency" do
    it "returns bob" do
      expect(create(:bolivia_bank_account).currency).to eq("bob")
    end
  end

  describe "#routing_number" do
    it "returns valid for 3 digits" do
      ba = create(:bolivia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("040")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bolivia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 1 to 3 digits only" do
      expect(build(:bolivia_bank_account, bank_code: "1")).to be_valid
      expect(build(:bolivia_bank_account, bank_code: "12")).to be_valid
      expect(build(:bolivia_bank_account, bank_code: "123")).to be_valid
      expect(build(:bolivia_bank_account, bank_code: "1234")).not_to be_valid
      expect(build(:bolivia_bank_account, bank_code: "a12")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows 10 to 15 digits only" do
      expect(build(:bolivia_bank_account, account_number: "1234567890")).to be_valid
      expect(build(:bolivia_bank_account, account_number: "123456789012345")).to be_valid
      expect(build(:bolivia_bank_account, account_number: "123456789")).not_to be_valid
      expect(build(:bolivia_bank_account, account_number: "1234567890123456")).not_to be_valid
      expect(build(:bolivia_bank_account, account_number: "12345a7890")).not_to be_valid
    end
  end
end
