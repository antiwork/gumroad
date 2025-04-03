# frozen_string_literal: true

require "spec_helper"

describe QatarBankAccount do
  describe "#bank_account_type" do
    it "returns QA" do
      expect(create(:qatar_bank_account).bank_account_type).to eq("QA")
    end
  end

  describe "#country" do
    it "returns QA" do
      expect(create(:qatar_bank_account).country).to eq("QA")
    end
  end

  describe "#currency" do
    it "returns qar" do
      expect(create(:qatar_bank_account).currency).to eq("qar")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:qatar_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAQAQAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:qatar_bank_account, account_number_last_four: "8901").account_number_visual).to eq("******8901")
    end
  end

  describe "#validate_bank_code" do
    it "allows 11 characters only" do
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXX")).to be_valid
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQA")).not_to be_valid
      expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXXX")).not_to be_valid
    end
  end
end
