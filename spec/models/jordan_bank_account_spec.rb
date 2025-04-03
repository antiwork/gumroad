# frozen_string_literal: true

describe JordanBankAccount do
  describe "#bank_account_type" do
    it "returns JO" do
      expect(create(:jordan_bank_account).bank_account_type).to eq("JO")
    end
  end

  describe "#country" do
    it "returns JO" do
      expect(create(:jordan_bank_account).country).to eq("JO")
    end
  end

  describe "#currency" do
    it "returns jod" do
      expect(create(:jordan_bank_account).currency).to eq("jod")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:jordan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAJOJOXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:jordan_bank_account, account_number_last_four: "5678").account_number_visual).to eq("JO******5678")
    end
  end
end
