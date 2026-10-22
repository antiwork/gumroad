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

  describe "bank code validation" do
    it "accepts 8 and 11 characters" do
      expect(build(:albania_bank_account, bank_number: "AAAAALTX")).to be_valid
      expect(build(:albania_bank_account, bank_number: "AAAAALTXXXX")).to be_valid
    end

    it "rejects 9, 10, 12 characters and embedded newlines" do
      %w[AAAAALTXX AAAAALTXXX AAAAALTXXXXX].each do |code|
        expect(build(:albania_bank_account, bank_number: code)).not_to be_valid
      end
      expect(build(:albania_bank_account, bank_number: "AAAAALTX\nXXX")).not_to be_valid
    end

    it "does not block unrelated saves of a legacy 9-character code" do
      account = create(:albania_bank_account)
      account.update_column(:bank_number, "AAAAALTXX")
      expect(account.reload.update(deleted_at: Time.current)).to be(true)
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:albania_bank_account, account_number_last_four: "4567").account_number_visual).to eq("AL******4567")
    end
  end
end
