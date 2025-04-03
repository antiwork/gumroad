# frozen_string_literal: true

require "spec_helper"

describe SriLankaBankAccount do
  describe "#bank_account_type" do
    it "returns LK" do
      expect(create(:sri_lanka_bank_account).bank_account_type).to eq("LK")
    end
  end

  describe "#country" do
    it "returns LK" do
      expect(create(:sri_lanka_bank_account).country).to eq("LK")
    end
  end

  describe "#currency" do
    it "returns lkr" do
      expect(create(:sri_lanka_bank_account).currency).to eq("lkr")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 to 11 characters" do
      ba = create(:sri_lanka_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAALKLXXXX-7010999")
    end
  end

  describe "#branch_code" do
    it "returns the branch code" do
      bank_account = create(:sri_lanka_bank_account, branch_code: "7010999")
      expect(bank_account.branch_code).to eq("7010999")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:sri_lanka_bank_account, account_number_last_four: "2345").account_number_visual).to eq("******2345")
    end
  end

  describe "#validate_branch_code" do
    it "allows exactly 7 digits" do
      expect(build(:sri_lanka_bank_account, branch_code: "7010999")).to be_valid
      expect(build(:sri_lanka_bank_account, branch_code: "701099")).not_to be_valid
      expect(build(:sri_lanka_bank_account, branch_code: "70109990")).not_to be_valid
    end
  end

  describe "#validate_bank_code" do
    it "allows 11 characters only" do
      expect(build(:sri_lanka_bank_account, bank_code: "AAAALKLXXXX")).to be_valid
      expect(build(:sri_lanka_bank_account, bank_code: "AAAALKLXXXXX")).not_to be_valid
      expect(build(:sri_lanka_bank_account, bank_code: "AAAALKLXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows 10 to 18 digits only" do
      expect(build(:sri_lanka_bank_account, account_number: "0000012345")).to be_valid
      expect(build(:sri_lanka_bank_account, account_number: "000001234567890123")).to be_valid
      expect(build(:sri_lanka_bank_account, account_number: "000001234")).not_to be_valid
      expect(build(:sri_lanka_bank_account, account_number: "0000012345678901234")).not_to be_valid
    end
  end
end
