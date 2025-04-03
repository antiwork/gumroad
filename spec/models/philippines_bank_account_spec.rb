# frozen_string_literal: true

require "spec_helper"

describe PhilippinesBankAccount do
  describe "#bank_account_type" do
    it "returns philippines" do
      expect(create(:philippines_bank_account).bank_account_type).to eq("PH")
    end
  end

  describe "#country" do
    it "returns PH" do
      expect(create(:philippines_bank_account).country).to eq("PH")
    end
  end

  describe "#currency" do
    it "returns php" do
      expect(create(:philippines_bank_account).currency).to eq("php")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:philippines_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("BCDEFGHI123")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:philippines_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:philippines_bank_account, bank_code: "BCDEFGHI")).to be_valid
      expect(build(:philippines_bank_account, bank_code: "BCDEFGHI1")).to be_valid
      expect(build(:philippines_bank_account, bank_code: "BCDEFGHI12")).to be_valid
      expect(build(:philippines_bank_account, bank_code: "BCDEFGHI123")).to be_valid
      expect(build(:philippines_bank_account, bank_code: "BCDEFGH")).not_to be_valid
      expect(build(:philippines_bank_account, bank_code: "BCDEFGHI1234")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:philippines_bank_account, account_number: "1")).to be_valid
      expect(build(:philippines_bank_account, account_number: "123456789")).to be_valid
      expect(build(:philippines_bank_account, account_number: "12345678901234567")).to be_valid

      ph_bank_account = build(:philippines_bank_account, account_number: "ABCDEFGHIJKL")
      expect(ph_bank_account).to_not be_valid
      expect(ph_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ph_bank_account = build(:philippines_bank_account, account_number: "123456789012345678")
      expect(ph_bank_account).to_not be_valid
      expect(ph_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
