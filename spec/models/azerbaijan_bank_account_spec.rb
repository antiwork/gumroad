# frozen_string_literal: true

require "spec_helper"

describe AzerbaijanBankAccount do
  describe "#bank_account_type" do
    it "returns AZ" do
      expect(create(:azerbaijan_bank_account).bank_account_type).to eq("AZ")
    end
  end

  describe "#country" do
    it "returns AZ" do
      expect(create(:azerbaijan_bank_account).country).to eq("AZ")
    end
  end

  describe "#currency" do
    it "returns azn" do
      expect(create(:azerbaijan_bank_account).currency).to eq("azn")
    end
  end

  describe "#routing_number" do
    it "returns valid for 6 digits with hyphen after 3" do
      ba = create(:azerbaijan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("123456-123456")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:azerbaijan_bank_account, account_number_last_four: "7890").account_number_visual).to eq("AZ******7890")
    end
  end

  describe "#validate_bank_code" do
    it "allows 6 digits only" do
      expect(build(:azerbaijan_bank_account, bank_code: "123456")).to be_valid
      expect(build(:azerbaijan_bank_account, bank_code: "12345")).not_to be_valid
      expect(build(:azerbaijan_bank_account, bank_code: "1234567")).not_to be_valid
      expect(build(:azerbaijan_bank_account, bank_code: "ABCDEF")).not_to be_valid
    end
  end

  describe "#validate_branch_code" do
    it "allows 6 digits only" do
      expect(build(:azerbaijan_bank_account, branch_code: "123456")).to be_valid
      expect(build(:azerbaijan_bank_account, branch_code: "12345")).not_to be_valid
      expect(build(:azerbaijan_bank_account, branch_code: "1234567")).not_to be_valid
      expect(build(:azerbaijan_bank_account, branch_code: "ABCDEF")).not_to be_valid
    end
  end
end
