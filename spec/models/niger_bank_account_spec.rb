# frozen_string_literal: true

describe NigerBankAccount do
  describe "#bank_account_type" do
    it "returns NE" do
      expect(create(:niger_bank_account).bank_account_type).to eq("NE")
    end
  end

  describe "#country" do
    it "returns NE" do
      expect(create(:niger_bank_account).country).to eq("NE")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:niger_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:niger_bank_account, account_number_last_four: "0268").account_number_visual).to eq("NE******0268")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:niger_bank_account).routing_number).to be nil
    end
  end
end
