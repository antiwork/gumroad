# frozen_string_literal: true

require "spec_helper"

describe IsraelBankAccount do
  describe "#bank_account_type" do
    it "returns IL" do
      expect(create(:israel_bank_account).bank_account_type).to eq("IL")
    end
  end

  describe "#country" do
    it "returns IL" do
      expect(create(:israel_bank_account).country).to eq("IL")
    end
  end

  describe "#currency" do
    it "returns ils" do
      expect(create(:israel_bank_account).currency).to eq("ils")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:israel_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:israel_bank_account, account_number_last_four: "9999").account_number_visual).to eq("IL******9999")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:israel_bank_account)).to be_valid
      expect(build(:israel_bank_account, account_number: "IL62 0108 0000 0009 9999 999")).to be_valid

      il_bank_account = build(:israel_bank_account, account_number: "IL12345")
      expect(il_bank_account).to_not be_valid
      expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      il_bank_account = build(:israel_bank_account, account_number: "DE6508000000192000145399")
      expect(il_bank_account).to_not be_valid
      expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      il_bank_account = build(:israel_bank_account, account_number: "8937040044053201300000")
      expect(il_bank_account).to_not be_valid
      expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      il_bank_account = build(:israel_bank_account, account_number: "ILABCDE")
      expect(il_bank_account).to_not be_valid
      expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
