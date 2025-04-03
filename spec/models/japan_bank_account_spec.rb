# frozen_string_literal: true

require "spec_helper"

describe JapanBankAccount do
  describe "#bank_account_type" do
    it "returns Japan" do
      expect(create(:japan_bank_account).bank_account_type).to eq("JP")
    end
  end

  describe "#country" do
    it "returns JP" do
      expect(create(:japan_bank_account).country).to eq("JP")
    end
  end

  describe "#currency" do
    it "returns jpy" do
      expect(create(:japan_bank_account).currency).to eq("jpy")
    end
  end

  describe "#routing_number" do
    it "returns valid for 7 digits" do
      ba = create(:japan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("1100000")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:japan_bank_account, account_number_last_four: "8912").account_number_visual).to eq("******8912")
    end
  end

  describe "#validate_bank_code" do
    it "allows 4 digits only" do
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
      expect(build(:japan_bank_account, bank_code: "BANK", branch_code: "000")).not_to be_valid

      expect(build(:japan_bank_account, bank_code: "ABC", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "123", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "TESTK", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "12345", branch_code: "000")).not_to be_valid
    end
  end

  describe "#validate_branch_code" do
    it "allows 3 digits only" do
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "ABC")).not_to be_valid

      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "AB")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "12")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "TEST")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "1234")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:japan_bank_account, account_number: "0001234")).to be_valid
      expect(build(:japan_bank_account, account_number: "1234")).to be_valid
      expect(build(:japan_bank_account, account_number: "12345678")).to be_valid

      jp_bank_account = build(:japan_bank_account, account_number: "ABCDEFG")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      jp_bank_account = build(:japan_bank_account, account_number: "123456789")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      jp_bank_account = build(:japan_bank_account, account_number: "123")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
