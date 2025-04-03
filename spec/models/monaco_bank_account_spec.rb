# frozen_string_literal: true

describe MonacoBankAccount do
  describe "#bank_account_type" do
    it "returns MC" do
      expect(create(:monaco_bank_account).bank_account_type).to eq("MC")
    end
  end

  describe "#country" do
    it "returns MC" do
      expect(create(:monaco_bank_account).country).to eq("MC")
    end
  end

  describe "#currency" do
    it "returns eur" do
      expect(create(:monaco_bank_account).currency).to eq("eur")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:monaco_bank_account, account_number_last_four: "6789").account_number_visual).to eq("MC******6789")
    end
  end
end
