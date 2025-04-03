# frozen_string_literal: true

require "spec_helper"

describe SwissBankAccount do
  describe "#bank_account_type" do
    it "returns swiss" do
      expect(create(:swiss_bank_account).bank_account_type).to eq("CH")
    end
  end

  describe "#country" do
    it "returns CH" do
      expect(create(:swiss_bank_account).country).to eq("CH")
    end
  end

  describe "#currency" do
    it "returns chf" do
      expect(create(:swiss_bank_account).currency).to eq("chf")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:swiss_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:swiss_bank_account, account_number_last_four: "3000").account_number_visual).to eq("CH******3000")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:swiss_bank_account)).to be_valid
      expect(build(:swiss_bank_account, account_number: "CH1234567890123456789")).to be_valid

      ch_bank_account = build(:swiss_bank_account, account_number: "CH12345")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ch_bank_account = build(:swiss_bank_account, account_number: "DE9300762011623852957")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ch_bank_account = build(:swiss_bank_account, account_number: "8937040044053201300000")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ch_bank_account = build(:swiss_bank_account, account_number: "CHABCDE")
      expect(ch_bank_account).to_not be_valid
      expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
