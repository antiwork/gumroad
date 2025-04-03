# frozen_string_literal: true

require "spec_helper"

describe ParaguayBankAccount do
  describe "#bank_account_type" do
    it "returns PY" do
      expect(create(:paraguay_bank_account).bank_account_type).to eq("PY")
    end
  end

  describe "#country" do
    it "returns PY" do
      expect(create(:paraguay_bank_account).country).to eq("PY")
    end
  end

  describe "#currency" do
    it "returns pyg" do
      expect(create(:paraguay_bank_account).currency).to eq("pyg")
    end
  end

  describe "#bank_code" do
    it "returns valid for 1 to 2 characters" do
      expect(create(:paraguay_bank_account, bank_code: "12")).to be_valid
      expect(create(:paraguay_bank_account, bank_code: "1")).to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:paraguay_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:paraguay_bank_account)).to be_valid
      expect(build(:paraguay_bank_account, account_number: "1234567890123456")).to be_valid
      expect(build(:paraguay_bank_account, account_number: "123")).to be_valid

      py_bank_account = build(:paraguay_bank_account, account_number: "12345678901234567")
      expect(py_bank_account).to_not be_valid
      expect(py_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      py_bank_account = build(:paraguay_bank_account, account_number: "ABC123")
      expect(py_bank_account).to_not be_valid
      expect(py_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
