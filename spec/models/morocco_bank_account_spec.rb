# frozen_string_literal: true

describe MoroccoBankAccount do
  describe "#bank_account_type" do
    it "returns Morocco" do
      expect(create(:morocco_bank_account).bank_account_type).to eq("MA")
    end
  end

  describe "#country" do
    it "returns MA" do
      expect(create(:morocco_bank_account).country).to eq("MA")
    end
  end

  describe "#currency" do
    it "returns mad" do
      expect(create(:morocco_bank_account).currency).to eq("mad")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:morocco_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMAMAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:morocco_bank_account, account_number_last_four: "9123").account_number_visual).to eq("MA******9123")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:morocco_bank_account)).to be_valid
      expect(build(:morocco_bank_account, account_number: "MA64011519000001205000534921")).to be_valid
      expect(build(:morocco_bank_account, account_number: "MA62370400440532013001")).to be_valid

      ma_bank_account = build(:morocco_bank_account, account_number: "MA12345")
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ma_bank_account = build(:morocco_bank_account, account_number: "DE61109010140000071219812874")
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ma_bank_account = build(:morocco_bank_account, account_number: "8937040044053201300000")
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ma_bank_account = build(:morocco_bank_account, account_number: "CRABCDE")
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
