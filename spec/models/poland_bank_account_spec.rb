# frozen_string_literal: true

require "spec_helper"

describe PolandBankAccount do
  describe "#bank_account_type" do
    it "returns poland" do
      expect(create(:poland_bank_account).bank_account_type).to eq("PL")
    end
  end

  describe "#country" do
    it "returns PL" do
      expect(create(:poland_bank_account).country).to eq("PL")
    end
  end

  describe "#currency" do
    it "returns pln" do
      expect(create(:poland_bank_account).currency).to eq("pln")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:poland_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:poland_bank_account, account_number_last_four: "2874").account_number_visual).to eq("PL******2874")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:poland_bank_account)).to be_valid
      expect(build(:poland_bank_account, account_number: "PL61 1090 1014 0000 0712 1981 2874")).to be_valid

      pl_bank_account = build(:poland_bank_account, account_number: "PL12345")
      expect(pl_bank_account).to_not be_valid
      expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pl_bank_account = build(:poland_bank_account, account_number: "DE61109010140000071219812874")
      expect(pl_bank_account).to_not be_valid
      expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pl_bank_account = build(:poland_bank_account, account_number: "8937040044053201300000")
      expect(pl_bank_account).to_not be_valid
      expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pl_bank_account = build(:poland_bank_account, account_number: "PLABCDE")
      expect(pl_bank_account).to_not be_valid
      expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
