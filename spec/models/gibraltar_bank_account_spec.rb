# frozen_string_literal: true

require "spec_helper"

describe GibraltarBankAccount do
  describe "#bank_account_type" do
    it "returns gibraltar" do
      expect(create(:gibraltar_bank_account).bank_account_type).to eq("GI")
    end
  end

  describe "#country" do
    it "returns GI" do
      expect(create(:gibraltar_bank_account).country).to eq("GI")
    end
  end

  describe "#currency" do
    it "returns gbp" do
      expect(create(:gibraltar_bank_account).currency).to eq("gbp")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:gibraltar_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:gibraltar_bank_account, account_number_last_four: "0000").account_number_visual).to eq("GI******0000")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:gibraltar_bank_account)).to be_valid
      expect(build(:gibraltar_bank_account, account_number: "GI75NWBK000000007099453")).to be_valid

      gi_bank_account = build(:gibraltar_bank_account, account_number: "GI12345")
      expect(gi_bank_account).to_not be_valid
      expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gi_bank_account = build(:gibraltar_bank_account, account_number: "DE61109010140000071219812874")
      expect(gi_bank_account).to_not be_valid
      expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gi_bank_account = build(:gibraltar_bank_account, account_number: "8937040044053201300000")
      expect(gi_bank_account).to_not be_valid
      expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gi_bank_account = build(:gibraltar_bank_account, account_number: "GIABCDE")
      expect(gi_bank_account).to_not be_valid
      expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
