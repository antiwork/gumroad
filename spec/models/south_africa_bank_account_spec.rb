# frozen_string_literal: true

require "spec_helper"

describe SouthAfricaBankAccount do
  describe "#bank_account_type" do
    it "returns ZA" do
      expect(create(:south_africa_bank_account).bank_account_type).to eq("ZA")
    end
  end

  describe "#country" do
    it "returns ZA" do
      expect(create(:south_africa_bank_account).country).to eq("ZA")
    end
  end

  describe "#currency" do
    it "returns zar" do
      expect(create(:south_africa_bank_account).currency).to eq("zar")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 characters" do
      ba = create(:south_africa_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("FIRNZAJJ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:south_africa_bank_account, account_number_last_four: "1234").account_number_visual).to eq("******1234")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:south_africa_bank_account, bank_code: "FIRNZAJJ")).to be_valid
      expect(build(:south_africa_bank_account, bank_code: "FIRNZAJJXXX")).to be_valid
      expect(build(:south_africa_bank_account, bank_code: "FIRNZAJ")).not_to be_valid
      expect(build(:south_africa_bank_account, bank_code: "FIRNZAJJXXXX")).not_to be_valid
    end
  end
end
