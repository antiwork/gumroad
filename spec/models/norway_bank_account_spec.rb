# frozen_string_literal: true

require "spec_helper"

describe NorwayBankAccount do
  describe "#bank_account_type" do
    it "returns NO" do
      expect(create(:norway_bank_account).bank_account_type).to eq("NO")
    end
  end

  describe "#country" do
    it "returns NO" do
      expect(create(:norway_bank_account).country).to eq("NO")
    end
  end

  describe "#currency" do
    it "returns nok" do
      expect(create(:norway_bank_account).currency).to eq("nok")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:norway_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:norway_bank_account, account_number_last_four: "7947").account_number_visual).to eq("******7947")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:norway_bank_account)).to be_valid
      expect(build(:norway_bank_account, account_number: "NO9386011117947")).to be_valid

      no_bank_account = build(:norway_bank_account, account_number: "NO938601111")
      expect(no_bank_account).to_not be_valid
      expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      no_bank_account = build(:norway_bank_account, account_number: "NOABCDEFGHIJKLM")
      expect(no_bank_account).to_not be_valid
      expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      no_bank_account = build(:norway_bank_account, account_number: "NO9386011117947123")
      expect(no_bank_account).to_not be_valid
      expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      no_bank_account = build(:norway_bank_account, account_number: "129386011117947")
      expect(no_bank_account).to_not be_valid
      expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
