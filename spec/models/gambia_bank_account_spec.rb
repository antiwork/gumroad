# frozen_string_literal: true

require "spec_helper"

describe GambiaBankAccount do
  describe "#bank_account_type" do
    it "returns GM" do
      expect(create(:gambia_bank_account).bank_account_type).to eq("GM")
    end
  end

  describe "#country" do
    it "returns GM" do
      expect(create(:gambia_bank_account).country).to eq("GM")
    end
  end

  describe "#currency" do
    it "returns gmd" do
      expect(create(:gambia_bank_account).currency).to eq("gmd")
    end
  end

  describe "#routing_number" do
    it "returns the SWIFT/BIC code" do
      ba = create(:gambia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAGMGMXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:gambia_bank_account, account_number_last_four: "0789").account_number_visual).to eq("******0789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:gambia_bank_account, bank_code: "AGIXGMGM")).to be_valid       # 8 chars
      expect(build(:gambia_bank_account, bank_code: "AAAAGMGMXYZ")).to be_valid    # 11 chars
      expect(build(:gambia_bank_account, bank_code: "AGIXGMG")).not_to be_valid    # too short
      expect(build(:gambia_bank_account, bank_code: "AAAAGMGMXYZZ")).not_to be_valid # too long
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:gambia_bank_account)).to be_valid

      gm_bank_account = build(:gambia_bank_account, account_number: "00012300045600078")
      expect(gm_bank_account).to_not be_valid
      expect(gm_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gm_bank_account = build(:gambia_bank_account, account_number: "0001230004560007890")
      expect(gm_bank_account).to_not be_valid
      expect(gm_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gm_bank_account = build(:gambia_bank_account, account_number: "000123-00456-000789")
      expect(gm_bank_account).to_not be_valid
      expect(gm_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
