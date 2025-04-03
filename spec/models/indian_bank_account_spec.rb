# frozen_string_literal: true

require "spec_helper"

describe IndianBankAccount do
  describe "#bank_account_type" do
    it "returns Indian" do
      expect(create(:indian_bank_account).bank_account_type).to eq("IN")
    end
  end

  describe "#country" do
    it "returns IN" do
      expect(create(:indian_bank_account).country).to eq("IN")
    end
  end

  describe "#currency" do
    it "returns inr" do
      expect(create(:indian_bank_account).currency).to eq("inr")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:indian_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("HDFC0004051")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:indian_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_ifsc" do
    it "allows 11 characters only" do
      expect(build(:indian_bank_account, ifsc: "HDFC0004051")).to be_valid
      expect(build(:indian_bank_account, ifsc: "ICIC0123456")).to be_valid
      expect(build(:indian_bank_account, ifsc: "HDFC00040511")).not_to be_valid
      expect(build(:indian_bank_account, ifsc: "HDFC000405")).not_to be_valid
    end
  end
end
