# frozen_string_literal: true

require "spec_helper"

describe EgyptBankAccount do
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
    it "allows an 8-character BIC, or an 11-character one carrying a branch code" do
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX")).to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCXXXX")).to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX331")).to be_valid
    end

    it "rejects the lowercase and the lengths Stripe's EG directory refuses outright" do
      expect(build(:egypt_bank_account, bank_code: "nbegegcx")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCXgcx")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGC")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX3311")).not_to be_valid
    end

    it "names the expected format in the error" do
      ba = build(:egypt_bank_account, bank_code: "nbegegcx")
      ba.valid?
      expect(ba.errors.full_messages).to include("Enter your bank's SWIFT/BIC code in capitals: 8 characters, or 11 including the branch code (for example NBEGEGCX).")
    end

    it "does not re-validate a pre-existing code on an unrelated save" do
      ba = build(:egypt_bank_account, bank_code: "NBEGEGCXgcx")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a code the save is changing" do
      ba = build(:egypt_bank_account, bank_code: "NBEGEGCX")
      ba.save!(validate: false)

      ba.bank_code = "NBEGEGCXgcx"
      expect(ba).not_to be_valid
    end
  end
end
