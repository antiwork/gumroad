# frozen_string_literal: true

describe MozambiqueBankAccount do
  describe "#bank_account_type" do
    it "returns MZ" do
      expect(create(:mozambique_bank_account).bank_account_type).to eq("MZ")
    end
  end

  describe "#country" do
    it "returns MZ" do
      expect(create(:mozambique_bank_account).country).to eq("MZ")
    end
  end

  describe "#currency" do
    it "returns mzn" do
      expect(create(:mozambique_bank_account).currency).to eq("mzn")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:mozambique_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMZMXXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:mozambique_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:mozambique_bank_account)).to be_valid
      expect(build(:mozambique_bank_account, account_number: "001234567890123456789")).to be_valid
      expect(build(:mozambique_bank_account, account_number: "00123456789012345678")).not_to be_valid
      expect(build(:mozambique_bank_account, account_number: "0012345678901234567890")).not_to be_valid
    end
  end
end
