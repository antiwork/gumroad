# frozen_string_literal: true

require "spec_helper"

describe AngolaBankAccount do
  describe "#bank_account_type" do
    it "returns AO" do
      expect(create(:angola_bank_account).bank_account_type).to eq("AO")
    end
  end

  describe "#country" do
    it "returns AO" do
      expect(create(:angola_bank_account).country).to eq("AO")
    end
  end

  describe "#currency" do
    it "returns aoa" do
      expect(create(:angola_bank_account).currency).to eq("aoa")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:angola_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAAOAOXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:angola_bank_account, account_number_last_four: "0102").account_number_visual).to eq("AO******0102")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXX")).to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOAO")).to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOA")).not_to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
    end

    it "accepts a valid 25-character IBAN" do
      expect(build(:angola_bank_account, account_number: "AO06004400006729503010102")).to be_valid
    end

    it "accepts a valid 21-digit NIB" do
      expect(build(:angola_bank_account, account_number: "004400006729503010102")).to be_valid
    end

    it "accepts an IBAN with whitespace" do
      expect(build(:angola_bank_account, account_number: "AO06 0044 0000 6729 5030 10102")).to be_valid
    end

    it "rejects an invalid account number" do
      expect(build(:angola_bank_account, account_number: "INVALID")).not_to be_valid
    end

    it "rejects a non-AO IBAN" do
      expect(build(:angola_bank_account, account_number: "DE89370400440532013000")).not_to be_valid
    end
  end
end
