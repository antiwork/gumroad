# frozen_string_literal: true

describe KazakhstanBankAccount do
  describe "#bank_account_type" do
    it "returns KZ" do
      expect(create(:kazakhstan_bank_account).bank_account_type).to eq("KZ")
    end
  end

  describe "#country" do
    it "returns KZ" do
      expect(create(:kazakhstan_bank_account).country).to eq("KZ")
    end
  end

  describe "#currency" do
    it "returns kzt" do
      expect(create(:kazakhstan_bank_account).currency).to eq("kzt")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 to 11 characters" do
      expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZ")).to be_valid
      expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZX")).to be_valid
      expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZXX")).to be_valid
      expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZXXX")).to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:kazakhstan_bank_account, account_number_last_four: "0123").account_number_visual).to eq("KZ******0123")
    end
  end
end
