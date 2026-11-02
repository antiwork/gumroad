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

  describe "copied example bank code" do
    it "refuses a new account with 12345678" do
      account = build(:vietnam_bank_account, bank_code: "12345678")

      expect(account).not_to be_valid
      expect(account.errors.full_messages.to_sentence).to eq("Enter the 8-digit code of your own bank.")
    end

    it "does not block saving a stored row whose bank code is unchanged" do
      account = create(:vietnam_bank_account)
      account.update_column(:bank_number, "12345678")

      expect(account.reload.update(account_holder_full_name: "Renamed Creator")).to be(true)
    end
  end
end
