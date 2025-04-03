# frozen_string_literal: true

describe BosniaAndHerzegovinaBankAccount do
  describe "#bank_account_type" do
    it "returns BA" do
      expect(create(:bosnia_and_herzegovina_bank_account).bank_account_type).to eq("BA")
    end
  end

  describe "#country" do
    it "returns BA" do
      expect(create(:bosnia_and_herzegovina_bank_account).country).to eq("BA")
    end
  end

  describe "#currency" do
    it "returns bam" do
      expect(create(:bosnia_and_herzegovina_bank_account).currency).to eq("bam")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:bosnia_and_herzegovina_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABABAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bosnia_and_herzegovina_bank_account, account_number_last_four: "6000").account_number_visual).to eq("BA******6000")
    end
  end
end
