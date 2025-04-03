# frozen_string_literal: true

require "spec_helper"

describe KenyaBankAccount do
  describe "#bank_account_type" do
    it "returns EG" do
      expect(create(:egypt_bank_account).bank_account_type).to eq("EG")
    end
  end

  describe "#country" do
    it "returns EG" do
      expect(create(:egypt_bank_account).country).to eq("EG")
    end
  end

  describe "#currency" do
    it "returns egp" do
      expect(create(:egypt_bank_account).currency).to eq("egp")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:egypt_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("NBEGEGCX331")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:egypt_bank_account, account_number_last_four: "0002").account_number_visual).to eq("******0002")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX")).to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX331")).to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGC")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX3311")).not_to be_valid
    end
  end
end
