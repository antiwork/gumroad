# frozen_string_literal: true

require "spec_helper"

describe SanMarinoBankAccount do
  describe "#bank_account_type" do
    it "returns SM" do
      expect(create(:san_marino_bank_account).bank_account_type).to eq("SM")
    end
  end

  describe "#country" do
    it "returns SM" do
      expect(create(:san_marino_bank_account).country).to eq("SM")
    end
  end

  describe "#currency" do
    it "returns eur" do
      expect(create(:san_marino_bank_account).currency).to eq("eur")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:san_marino_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAASMSMXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:san_marino_bank_account, account_number_last_four: "0100").account_number_visual).to eq("SM******0100")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:san_marino_bank_account, bank_code: "AAAASMSMXXX")).to be_valid
      expect(build(:san_marino_bank_account, bank_code: "AAAASMSM")).to be_valid
      expect(build(:san_marino_bank_account, bank_code: "AAAASMS")).not_to be_valid
      expect(build(:san_marino_bank_account, bank_code: "AAAASMSMXXXX")).not_to be_valid
    end
  end
end
