# frozen_string_literal: true

require "spec_helper"

describe TaiwanBankAccount do
  describe "#bank_account_type" do
    it "returns Taiwan" do
      expect(create(:taiwan_bank_account).bank_account_type).to eq("TW")
    end
  end

  describe "#country" do
    it "returns TW" do
      expect(create(:taiwan_bank_account).country).to eq("TW")
    end
  end

  describe "#currency" do
    it "returns twd" do
      expect(create(:taiwan_bank_account).currency).to eq("twd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:taiwan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAATWTXXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:taiwan_bank_account, account_number_last_four: "4567").account_number_visual).to eq("******4567")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:taiwan_bank_account, bank_code: "AAAATWTXXXX")).to be_valid
      expect(build(:taiwan_bank_account, bank_code: "AAAATWTX")).to be_valid
      expect(build(:taiwan_bank_account, bank_code: "AAAATWT")).not_to be_valid
      expect(build(:taiwan_bank_account, bank_code: "AAAATWTXXXXX")).not_to be_valid
    end
  end
end
