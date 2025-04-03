# frozen_string_literal: true

require "spec_helper"

describe EuropeanBankAccount do
  describe "#bank_account_type" do
    it "returns european" do
      expect(create(:european_bank_account).bank_account_type).to eq("EU")
      expect(create(:fr_bank_account).bank_account_type).to eq("EU")
      expect(create(:nl_bank_account).bank_account_type).to eq("EU")
    end
  end

  describe "#country" do
    it "returns the country based on first two digits of the IBAN account number" do
      expect(create(:european_bank_account).country).to eq("DE")
      expect(create(:fr_bank_account).country).to eq("FR")
      expect(create(:nl_bank_account).country).to eq("NL")
    end
  end

  describe "#currency" do
    it "returns eur" do
      expect(create(:european_bank_account).currency).to eq("eur")
      expect(create(:fr_bank_account).currency).to eq("eur")
      expect(create(:nl_bank_account).currency).to eq("eur")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:european_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:european_bank_account, account_number_last_four: "3000").account_number_visual).to eq("DE******3000")
      expect(create(:fr_bank_account, account_number_last_four: "3000").account_number_visual).to eq("FR******3000")
      expect(create(:nl_bank_account, account_number_last_four: "3000").account_number_visual).to eq("NL******3000")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:european_bank_account, account_number: "DE89370400440532013000")).to be_valid
      expect(build(:european_bank_account, account_number: "FR1420041010050500013M02606")).to be_valid
      expect(build(:european_bank_account, account_number: "NL91ABNA0417164300")).to be_valid

      de_bank_account = build(:european_bank_account, account_number: "DE12345")
      expect(de_bank_account).to_not be_valid
      expect(de_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      fr_bank_account = build(:european_bank_account, account_number: "893704004405320130001234567")
      expect(fr_bank_account).to_not be_valid
      expect(fr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      nl_bank_account = build(:european_bank_account, account_number: "NLABCDE")
      expect(nl_bank_account).to_not be_valid
      expect(nl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
