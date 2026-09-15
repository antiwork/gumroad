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
    it "returns the bank code" do
      ba = create(:egypt_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("NBEGEGCX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:egypt_bank_account, account_number_last_four: "0002").account_number_visual).to eq("******0002")
    end
  end

  describe "#validate_bank_code" do
    it "allows an 8-character BIC, or an 11-character BIC padded with XXX" do
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX")).to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCXXXX")).to be_valid
    end

    it "rejects the branch-suffixed shapes Stripe's EG directory cannot resolve" do
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX331")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCXULL")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGC")).not_to be_valid
      expect(build(:egypt_bank_account, bank_code: "NBEGEGCX3311")).not_to be_valid
    end

    it "names the expected format in the error" do
      ba = build(:egypt_bank_account, bank_code: "NBEGEGCX331")
      ba.valid?
      expect(ba.errors.full_messages).to include("Enter your bank's 8-character SWIFT/BIC code (for example NBEGEGCX); the branch number is not part of it.")
    end

    it "does not re-validate a pre-existing branch-suffixed code on an unrelated save" do
      ba = build(:egypt_bank_account, bank_code: "NBEGEGCX331")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a branch-suffixed code when the code itself is being changed" do
      ba = build(:egypt_bank_account, bank_code: "NBEGEGCX")
      ba.save!(validate: false)

      ba.bank_code = "NBEGEGCX331"
      expect(ba).not_to be_valid
    end
  end
end
