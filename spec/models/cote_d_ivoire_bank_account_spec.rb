# frozen_string_literal: true

describe CoteDIvoireBankAccount do
  describe "#bank_account_type" do
    it "returns CI" do
      expect(create(:cote_d_ivoire_bank_account).bank_account_type).to eq("CI")
    end
  end

  describe "#country" do
    it "returns CI" do
      expect(create(:cote_d_ivoire_bank_account).country).to eq("CI")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:cote_d_ivoire_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:cote_d_ivoire_bank_account, account_number_last_four: "0589").account_number_visual).to eq("CI******0589")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:cote_d_ivoire_bank_account).routing_number).to be nil
    end
  end
end
