# frozen_string_literal: true

require "spec_helper"

describe ElSalvadorBankAccount do
  describe "#bank_account_type" do
    it "returns SV" do
      expect(create(:el_salvador_bank_account).bank_account_type).to eq("SV")
    end
  end

  describe "#country" do
    it "returns SV" do
      expect(create(:el_salvador_bank_account).country).to eq("SV")
    end
  end

  describe "#currency" do
    it "returns usd" do
      expect(create(:el_salvador_bank_account).currency).to eq("usd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:el_salvador_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAASVS1XXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:el_salvador_bank_account, account_number_last_four: "7890").account_number_visual).to eq("******7890")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1")).to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXX")).to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASV")).not_to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows only valid format" do
      expect(build(:el_salvador_bank_account, account_number: "SV44BCIE12345678901234567890")).to be_valid
      expect(build(:el_salvador_bank_account, account_number: "SV44BCIE123456789012345678")).not_to be_valid
      expect(build(:el_salvador_bank_account, account_number: "SV44BCIE123456789012345678901")).not_to be_valid
      expect(build(:el_salvador_bank_account, account_number: "SV44BCIE1234567890123456789O")).not_to be_valid
    end
  end
end
