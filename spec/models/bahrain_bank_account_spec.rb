# frozen_string_literal: true

describe BahrainBankAccount do
  describe "#bank_account_type" do
    it "returns BH" do
      expect(create(:bahrain_bank_account).bank_account_type).to eq("BH")
    end
  end

  describe "#country" do
    it "returns BH" do
      expect(create(:bahrain_bank_account).country).to eq("BH")
    end
  end

  describe "#currency" do
    it "returns bhd" do
      expect(create(:bahrain_bank_account).currency).to eq("bhd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:bahrain_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABHBMXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bahrain_bank_account, account_number_last_four: "BH00").account_number_visual).to eq("BH******BH00")
    end
  end
end
