# frozen_string_literal: true

describe BeninBankAccount do
  describe "#bank_account_type" do
    it "returns BJ" do
      expect(create(:benin_bank_account).bank_account_type).to eq("BJ")
    end
  end

  describe "#country" do
    it "returns BJ" do
      expect(create(:benin_bank_account).country).to eq("BJ")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:benin_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:benin_bank_account, account_number_last_four: "0769").account_number_visual).to eq("BJ******0769")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:benin_bank_account).routing_number).to be nil
    end
  end
end
