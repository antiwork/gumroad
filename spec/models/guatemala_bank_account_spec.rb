# frozen_string_literal: true

require "spec_helper"

describe GuatemalaBankAccount do
  describe "#bank_account_type" do
    it "returns GT" do
      expect(create(:guatemala_bank_account).bank_account_type).to eq("GT")
    end
  end

  describe "#country" do
    it "returns GT" do
      expect(create(:guatemala_bank_account).country).to eq("GT")
    end
  end

  describe "#currency" do
    it "returns gtq" do
      expect(create(:guatemala_bank_account).currency).to eq("gtq")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:guatemala_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAGTGCXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:guatemala_bank_account, account_number_last_four: "7890").account_number_visual).to eq("******7890")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:guatemala_bank_account, bank_code: "AAAAGTGCXYZ")).to be_valid
      expect(build(:guatemala_bank_account, bank_code: "AAAAGTGC")).to be_valid
      expect(build(:guatemala_bank_account, bank_code: "AAAAGTG")).not_to be_valid
      expect(build(:guatemala_bank_account, bank_code: "AAAAGTGCXYZZ")).not_to be_valid
    end
  end
end
