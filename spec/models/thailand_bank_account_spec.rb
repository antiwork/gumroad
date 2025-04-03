# frozen_string_literal: true

require "spec_helper"

describe ThailandBankAccount do
  describe "#bank_account_type" do
    it "returns thailand" do
      expect(create(:thailand_bank_account).bank_account_type).to eq("TH")
    end
  end

  describe "#country" do
    it "returns TH" do
      expect(create(:thailand_bank_account).country).to eq("TH")
    end
  end

  describe "#currency" do
    it "returns thb" do
      expect(create(:thailand_bank_account).currency).to eq("thb")
    end
  end

  describe "#routing_number" do
    it "returns valid for 3 digits" do
      ba = create(:thailand_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("999")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:thailand_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 3 digits only" do
      expect(build(:thailand_bank_account, bank_code: "111")).to be_valid
      expect(build(:thailand_bank_account, bank_code: "999")).to be_valid
      expect(build(:thailand_bank_account, bank_code: "ABCD")).not_to be_valid
      expect(build(:thailand_bank_account, bank_code: "1234")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:thailand_bank_account, account_number: "000123456789")).to be_valid
      expect(build(:thailand_bank_account, account_number: "123456789")).to be_valid
      expect(build(:thailand_bank_account, account_number: "123456789012345")).to be_valid

      th_bank_account = build(:thailand_bank_account, account_number: "ABCDEFGHIJKL")
      expect(th_bank_account).to_not be_valid
      expect(th_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      th_bank_account = build(:thailand_bank_account, account_number: "8937040044053201300000")
      expect(th_bank_account).to_not be_valid
      expect(th_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      th_bank_account = build(:thailand_bank_account, account_number: "12345")
      expect(th_bank_account).to_not be_valid
      expect(th_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
