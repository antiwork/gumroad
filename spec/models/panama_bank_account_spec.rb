# frozen_string_literal: true

require "spec_helper"

describe PanamaBankAccount do
  describe "#bank_account_type" do
    it "returns PA" do
      expect(create(:panama_bank_account).bank_account_type).to eq("PA")
    end
  end

  describe "#country" do
    it "returns PA" do
      expect(create(:panama_bank_account).country).to eq("PA")
    end
  end

  describe "#currency" do
    it "returns usd" do
      expect(create(:panama_bank_account).currency).to eq("usd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:panama_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAPAPAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:panama_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 11 characters only" do
      expect(build(:panama_bank_account, bank_number: "AAAAPAPAXXX")).to be_valid
      expect(build(:panama_bank_account, bank_number: "AAAAPAPAXX")).not_to be_valid
      expect(build(:panama_bank_account, bank_number: "AAAAPAPAXXXX")).not_to be_valid
    end
  end
end
