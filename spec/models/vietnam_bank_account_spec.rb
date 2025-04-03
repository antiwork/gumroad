# frozen_string_literal: true

require "spec_helper"

describe VietnamBankAccount do
  describe "#bank_account_type" do
    it "returns Vietnam" do
      expect(create(:vietnam_bank_account).bank_account_type).to eq("VN")
    end
  end

  describe "#country" do
    it "returns VN" do
      expect(create(:vietnam_bank_account).country).to eq("VN")
    end
  end

  describe "#currency" do
    it "returns vnd" do
      expect(create(:vietnam_bank_account).currency).to eq("vnd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 characters" do
      ba = create(:vietnam_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("01101100")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:vietnam_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 numbers only" do
      expect(build(:vietnam_bank_account, bank_code: "01101100")).to be_valid
      expect(build(:vietnam_bank_account, bank_code: "AAAATWTX")).not_to be_valid
      expect(build(:vietnam_bank_account, bank_code: "0110110")).not_to be_valid
      expect(build(:vietnam_bank_account, bank_code: "011011000")).not_to be_valid
    end
  end
end
