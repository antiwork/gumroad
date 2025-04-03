# frozen_string_literal: true

require "spec_helper"

describe KenyaBankAccount do
  describe "#bank_account_type" do
    it "returns KE" do
      expect(create(:kenya_bank_account).bank_account_type).to eq("KE")
    end
  end

  describe "#country" do
    it "returns KE" do
      expect(create(:kenya_bank_account).country).to eq("KE")
    end
  end

  describe "#currency" do
    it "returns kes" do
      expect(create(:kenya_bank_account).currency).to eq("kes")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:kenya_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("BARCKENXMDR")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:kenya_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:kenya_bank_account, bank_code: "BARCKENX")).to be_valid
      expect(build(:kenya_bank_account, bank_code: "BARCKENXMDR")).to be_valid
      expect(build(:kenya_bank_account, bank_code: "BARCKEN")).not_to be_valid
      expect(build(:kenya_bank_account, bank_code: "BARCKENXMDRX")).not_to be_valid
    end
  end
end
