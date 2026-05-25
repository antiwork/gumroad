# frozen_string_literal: true

require "spec_helper"

describe AngolaBankAccount do
  describe "#bank_account_type" do
    it "returns AO" do
      expect(create(:angola_bank_account).bank_account_type).to eq("AO")
    end
  end

  describe "#country" do
    it "returns AO" do
      expect(create(:angola_bank_account).country).to eq("AO")
    end
  end

  describe "#currency" do
    it "returns aoa" do
      expect(create(:angola_bank_account).currency).to eq("aoa")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:angola_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAAOAOXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:angola_bank_account, account_number_last_four: "0102").account_number_visual).to eq("AO******0102")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXX")).to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOAO")).to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOA")).not_to be_valid
      expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:angola_bank_account)).to be_valid
      expect(build(:angola_bank_account, account_number: "AO06004400006729503010102")).to be_valid

      ao_bank_account = build(:angola_bank_account, account_number: "AO12345")
      expect(ao_bank_account).not_to be_valid
      expect(ao_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ao_bank_account = build(:angola_bank_account, account_number: "DE61109010140000071219812874")
      expect(ao_bank_account).not_to be_valid
      expect(ao_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ao_bank_account = build(:angola_bank_account, account_number: "06004400006729503010102")
      expect(ao_bank_account).not_to be_valid
      expect(ao_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end

    it "accepts an IBAN with spaces between groups" do
      expect(build(:angola_bank_account, account_number: "AO06 0044 0000 6729 5030 1010 2")).to be_valid
    end

    it "accepts an IBAN with dashes between groups" do
      expect(build(:angola_bank_account, account_number: "AO06-0044-0000-6729-5030-1010-2")).to be_valid
    end
  end

  describe "normalization" do
    it "strips spaces from the saved account number so the value Stripe receives is clean" do
      ba = build(:angola_bank_account, account_number: "AO06 0044 0000 6729 5030 1010 2")
      ba.valid?
      expect(ba.send(:account_number_decrypted)).to eq("AO06004400006729503010102")
    end

    it "strips dashes from the saved account number" do
      ba = build(:angola_bank_account, account_number: "AO06-0044-0000-6729-5030-1010-2")
      ba.valid?
      expect(ba.send(:account_number_decrypted)).to eq("AO06004400006729503010102")
    end

    it "strips leading and trailing whitespace" do
      ba = build(:angola_bank_account, account_number: "  AO06004400006729503010102  ")
      ba.valid?
      expect(ba.send(:account_number_decrypted)).to eq("AO06004400006729503010102")
    end

    it "updates account_number_last_four to match the normalized value so the masked display is correct" do
      ba = build(:angola_bank_account,
                 account_number: "AO06 0044 0000 6729 5030 1010 2",
                 account_number_last_four: "10 2") # what UpdatePayoutMethod would persist pre-normalization
      ba.valid?
      expect(ba.account_number_last_four).to eq("0102")
      expect(ba.account_number_visual).to eq("AO******0102")
    end
  end
end
