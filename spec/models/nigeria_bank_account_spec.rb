# frozen_string_literal: true

describe NigeriaBankAccount do
  describe "#bank_account_type" do
    it "returns NG" do
      expect(create(:nigeria_bank_account).bank_account_type).to eq("NG")
    end
  end

  describe "#country" do
    it "returns NG" do
      expect(create(:nigeria_bank_account).country).to eq("NG")
    end
  end

  describe "#currency" do
    it "returns ngn" do
      expect(create(:nigeria_bank_account).currency).to eq("ngn")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:nigeria_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAANGLAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:nigeria_bank_account, account_number_last_four: "1112").account_number_visual).to eq("NG******1112")
    end
  end
end
