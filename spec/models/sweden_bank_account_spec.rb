# frozen_string_literal: true

require "spec_helper"

describe SwedenBankAccount do
  describe "#bank_account_type" do
    it "returns sweden" do
      expect(create(:sweden_bank_account).bank_account_type).to eq("SE")
    end
  end

  describe "#country" do
    it "returns SE" do
      expect(create(:sweden_bank_account).country).to eq("SE")
    end
  end

  describe "#currency" do
    it "returns sek" do
      expect(create(:sweden_bank_account).currency).to eq("sek")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:sweden_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:sweden_bank_account, account_number_last_four: "0003").account_number_visual).to eq("SE******0003")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:sweden_bank_account)).to be_valid
      expect(build(:sweden_bank_account, account_number: "SE35 5000 0000 0549 1000 0003")).to be_valid

      se_bank_account = build(:sweden_bank_account, account_number: "SE12345")
      expect(se_bank_account).to_not be_valid
      expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      se_bank_account = build(:sweden_bank_account, account_number: "DE61109010140000071219812874")
      expect(se_bank_account).to_not be_valid
      expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      se_bank_account = build(:sweden_bank_account, account_number: "8937040044053201300000")
      expect(se_bank_account).to_not be_valid
      expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      se_bank_account = build(:sweden_bank_account, account_number: "SEABCDE")
      expect(se_bank_account).to_not be_valid
      expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
