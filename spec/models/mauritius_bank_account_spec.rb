# frozen_string_literal: true

describe MauritiusBankAccount do
  describe "#bank_account_type" do
    it "returns MU" do
      expect(create(:mauritius_bank_account).bank_account_type).to eq("MU")
    end
  end

  describe "#country" do
    it "returns MA" do
      expect(create(:mauritius_bank_account).country).to eq("MU")
    end
  end

  describe "#currency" do
    it "returns mad" do
      expect(create(:mauritius_bank_account).currency).to eq("mur")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:mauritius_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMUMUXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:mauritius_bank_account, account_number_last_four: "9123").account_number_visual).to eq("MU******9123")
    end
  end
end
