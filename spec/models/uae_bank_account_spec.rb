# frozen_string_literal: true

require "spec_helper"

describe UaeBankAccount do
  describe "#bank_account_type" do
    it "returns AE" do
      expect(create(:uae_bank_account).bank_account_type).to eq("AE")
    end
  end

  describe "#country" do
    it "returns AE" do
      expect(create(:uae_bank_account).country).to eq("AE")
    end
  end

  describe "#currency" do
    it "returns aed" do
      expect(create(:uae_bank_account).currency).to eq("aed")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:uae_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:uae_bank_account, account_number_last_four: "3456").account_number_visual).to eq("AE******3456")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:uae_bank_account)).to be_valid
      expect(build(:uae_bank_account, account_number: "AE 0703 3123 4567 8901 2345 6")).to be_valid

      hu_bank_account = build(:uae_bank_account, account_number: "AE12345")
      expect(hu_bank_account).to_not be_valid
      expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      hu_bank_account = build(:uae_bank_account, account_number: "DE61109010140000071219812874")
      expect(hu_bank_account).to_not be_valid
      expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      hu_bank_account = build(:uae_bank_account, account_number: "8937040044053201300000")
      expect(hu_bank_account).to_not be_valid
      expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      hu_bank_account = build(:uae_bank_account, account_number: "AEABCDE")
      expect(hu_bank_account).to_not be_valid
      expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
