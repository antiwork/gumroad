# frozen_string_literal: true

describe AlbaniaBankAccount do
  describe "#bank_account_type" do
    it "returns AL" do
      expect(create(:albania_bank_account).bank_account_type).to eq("AL")
    end
  end

  describe "#country" do
    it "returns AL" do
      expect(create(:albania_bank_account).country).to eq("AL")
    end
  end

  describe "#currency" do
    it "returns all" do
      expect(create(:albania_bank_account).currency).to eq("all")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:albania_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAALTXXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:albania_bank_account, account_number_last_four: "4567").account_number_visual).to eq("AL******4567")
    end
  end
end
