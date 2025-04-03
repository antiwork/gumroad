# frozen_string_literal: true

require "spec_helper"

describe CzechRepublicBankAccount do
  describe "#bank_account_type" do
    it "returns CZ" do
      expect(create(:czech_republic_bank_account).bank_account_type).to eq("CZ")
    end
  end

  describe "#country" do
    it "returns CZ" do
      expect(create(:czech_republic_bank_account).country).to eq("CZ")
    end
  end

  describe "#currency" do
    it "returns czk" do
      expect(create(:czech_republic_bank_account).currency).to eq("czk")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:czech_republic_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:czech_republic_bank_account, account_number_last_four: "3000").account_number_visual).to eq("CZ******3000")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:czech_republic_bank_account)).to be_valid
      expect(build(:czech_republic_bank_account, account_number: "CZ65 0800 0000 1920 0014 5399")).to be_valid

      cz_bank_account = build(:czech_republic_bank_account, account_number: "CZ12345")
      expect(cz_bank_account).to_not be_valid
      expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cz_bank_account = build(:czech_republic_bank_account, account_number: "DE6508000000192000145399")
      expect(cz_bank_account).to_not be_valid
      expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cz_bank_account = build(:czech_republic_bank_account, account_number: "8937040044053201300000")
      expect(cz_bank_account).to_not be_valid
      expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cz_bank_account = build(:czech_republic_bank_account, account_number: "CZABCDE")
      expect(cz_bank_account).to_not be_valid
      expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
