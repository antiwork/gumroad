# frozen_string_literal: true

require "spec_helper"

describe PeruBankAccount do
  describe "#bank_account_type" do
    it "returns peru" do
      expect(create(:peru_bank_account).bank_account_type).to eq("PE")
    end
  end

  describe "#country" do
    it "returns PE" do
      expect(create(:peru_bank_account).country).to eq("PE")
    end
  end

  describe "#currency" do
    it "returns pen" do
      expect(create(:peru_bank_account).currency).to eq("pen")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:peru_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:peru_bank_account, account_number_last_four: "2874").account_number_visual).to eq("******2874")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:peru_bank_account)).to be_valid
      expect(build(:peru_bank_account, account_number: "01234567898765432101")).to be_valid

      pe_bank_account = build(:peru_bank_account, account_number: "012345678")
      expect(pe_bank_account).to_not be_valid
      expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pe_bank_account = build(:peru_bank_account, account_number: "ABCDEFGHIJKLMNOPQRSTUV")
      expect(pe_bank_account).to_not be_valid
      expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pe_bank_account = build(:peru_bank_account, account_number: "01234567898765432123456")
      expect(pe_bank_account).to_not be_valid
      expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pe_bank_account = build(:peru_bank_account, account_number: "012345678987654321234")
      expect(pe_bank_account).to_not be_valid
      expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
