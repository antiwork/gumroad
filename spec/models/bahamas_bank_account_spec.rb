# frozen_string_literal: true

require "spec_helper"

describe BahamasBankAccount do
  describe "#bank_account_type" do
    it "returns BS" do
      expect(create(:bahamas_bank_account).bank_account_type).to eq("BS")
    end
  end

  describe "#country" do
    it "returns BS" do
      expect(create(:bahamas_bank_account).country).to eq("BS")
    end
  end

  describe "#currency" do
    it "returns bsd" do
      expect(create(:bahamas_bank_account).currency).to eq("bsd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:bahamas_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABSNSXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bahamas_bank_account, account_number_last_four: "1234").account_number_visual).to eq("******1234")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:bahamas_bank_account, bank_code: "AAAABSNS")).to be_valid
      expect(build(:bahamas_bank_account, bank_code: "AAAABSNSXXX")).to be_valid
      expect(build(:bahamas_bank_account, bank_code: "AAAABS")).not_to be_valid
      expect(build(:bahamas_bank_account, bank_code: "AAAABSNSXXXX")).not_to be_valid
    end
  end
end
