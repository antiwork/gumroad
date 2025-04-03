# frozen_string_literal: true

require "spec_helper"

describe KuwaitBankAccount do
  describe "#bank_account_type" do
    it "returns KW" do
      expect(create(:kuwait_bank_account).bank_account_type).to eq("KW")
    end
  end

  describe "#country" do
    it "returns KW" do
      expect(create(:kuwait_bank_account).country).to eq("KW")
    end
  end

  describe "#currency" do
    it "returns kwd" do
      expect(create(:kuwait_bank_account).currency).to eq("kwd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 10 characters" do
      ba = create(:kuwait_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAKWKWXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:kuwait_bank_account, account_number_last_four: "0101").account_number_visual).to eq("******0101")
    end
  end

  describe "#validate_bank_code" do
    it "allows only 8 to 11 characters" do
      expect(build(:kuwait_bank_account, bank_code: "AAAAKWKWXYZ")).to be_valid
      expect(build(:kuwait_bank_account, bank_code: "AAA0000X")).to be_valid
      expect(build(:kuwait_bank_account, bank_code: "AAAA0000XXXX")).not_to be_valid
      expect(build(:kuwait_bank_account, bank_code: "AAAA000")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows only 30 characters in the correct format" do
      expect(build(:kuwait_bank_account, account_number: "KW81CBKU0000000000001234560101")).to be_valid
      expect(build(:kuwait_bank_account, account_number: "KW81CBKU00000000000012345601012")).not_to be_valid
      expect(build(:kuwait_bank_account, account_number: "KW81CBKU000000000000123456")).not_to be_valid
      expect(build(:kuwait_bank_account, account_number: "KW81CBKU0000000000001234560101234")).not_to be_valid
    end
  end
end
