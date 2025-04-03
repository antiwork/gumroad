# frozen_string_literal: true

require "spec_helper"

describe NewZealandBankAccount do
  describe "#bank_account_type" do
    it "returns new zealand" do
      expect(create(:new_zealand_bank_account).bank_account_type).to eq("NZ")
    end
  end

  describe "#country" do
    it "returns NZ" do
      expect(create(:new_zealand_bank_account).country).to eq("NZ")
    end
  end

  describe "#currency" do
    it "returns nzd" do
      expect(create(:new_zealand_bank_account).currency).to eq("nzd")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:new_zealand_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:new_zealand_bank_account, account_number_last_four: "0010").account_number_visual).to eq("******0010")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:new_zealand_bank_account, account_number: "1100000000000010")).to be_valid
      expect(build(:new_zealand_bank_account, account_number: "1123456789012345")).to be_valid
      expect(build(:new_zealand_bank_account, account_number: "112345678901234")).to be_valid

      ch_bank_account = build(:new_zealand_bank_account, account_number: "NZ12345")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ch_bank_account = build(:new_zealand_bank_account, account_number: "11000000000000")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ch_bank_account = build(:new_zealand_bank_account, account_number: "CHABCDEFGHIJKLMNZ")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
