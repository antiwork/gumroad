# frozen_string_literal: true

require "spec_helper"

describe ArgentinaBankAccount do
  describe "#bank_account_type" do
    it "returns argentina" do
      expect(create(:argentina_bank_account).bank_account_type).to eq("AR")
    end
  end

  describe "#country" do
    it "returns AR" do
      expect(create(:argentina_bank_account).country).to eq("AR")
    end
  end

  describe "#currency" do
    it "returns ars" do
      expect(create(:argentina_bank_account).currency).to eq("ars")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:argentina_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:argentina_bank_account, account_number_last_four: "2874").account_number_visual).to eq("******2874")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:argentina_bank_account)).to be_valid
      expect(build(:argentina_bank_account, account_number: "0123456789876543212345")).to be_valid

      ar_bank_account = build(:argentina_bank_account, account_number: "012345678")
      expect(ar_bank_account).to_not be_valid
      expect(ar_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ar_bank_account = build(:argentina_bank_account, account_number: "ABCDEFGHIJKLMNOPQRSTUV")
      expect(ar_bank_account).to_not be_valid
      expect(ar_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ar_bank_account = build(:argentina_bank_account, account_number: "01234567898765432123456")
      expect(ar_bank_account).to_not be_valid
      expect(ar_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ar_bank_account = build(:argentina_bank_account, account_number: "012345678987654321234")
      expect(ar_bank_account).to_not be_valid
      expect(ar_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
