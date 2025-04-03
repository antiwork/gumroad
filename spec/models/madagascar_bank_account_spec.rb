# frozen_string_literal: true

describe MadagascarBankAccount do
  describe "#bank_account_type" do
    it "returns Madagascar" do
      expect(create(:madagascar_bank_account).bank_account_type).to eq("MG")
    end
  end

  describe "#country" do
    it "returns MG" do
      expect(create(:madagascar_bank_account).country).to eq("MG")
    end
  end

  describe "#currency" do
    it "returns mga" do
      expect(create(:madagascar_bank_account).currency).to eq("mga")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:madagascar_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMGMGXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:madagascar_bank_account, account_number_last_four: "0123").account_number_visual).to eq("******0123")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:madagascar_bank_account)).to be_valid
      expect(build(:madagascar_bank_account, account_number: "MG4800005000011234567890123")).to be_valid

      mg_bank_account = build(:madagascar_bank_account, account_number: "MG12345")
      expect(mg_bank_account).to_not be_valid
      expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      mg_bank_account = build(:madagascar_bank_account, account_number: "DE61109010140000071219812874")
      expect(mg_bank_account).to_not be_valid
      expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      mg_bank_account = build(:madagascar_bank_account, account_number: "8937040044053201300000")
      expect(mg_bank_account).to_not be_valid
      expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
