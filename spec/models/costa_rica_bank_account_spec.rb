# frozen_string_literal: true

describe CostaRicaBankAccount do
  describe "#bank_account_type" do
    it "returns Costa Rica" do
      expect(create(:costa_rica_bank_account).bank_account_type).to eq("CR")
    end
  end

  describe "#country" do
    it "returns CR" do
      expect(create(:costa_rica_bank_account).country).to eq("CR")
    end
  end

  describe "#currency" do
    it "returns crc" do
      expect(create(:costa_rica_bank_account).currency).to eq("crc")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:costa_rica_bank_account, account_number_last_four: "9123").account_number_visual).to eq("CR******9123")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:costa_rica_bank_account)).to be_valid
      expect(build(:costa_rica_bank_account, account_number: "CR 0401 0212 3678 5670 9123")).to be_valid

      cr_bank_account = build(:costa_rica_bank_account, account_number: "CR12345")
      expect(cr_bank_account).to_not be_valid
      expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cr_bank_account = build(:costa_rica_bank_account, account_number: "DE61109010140000071219812874")
      expect(cr_bank_account).to_not be_valid
      expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cr_bank_account = build(:costa_rica_bank_account, account_number: "8937040044053201300000")
      expect(cr_bank_account).to_not be_valid
      expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      cr_bank_account = build(:costa_rica_bank_account, account_number: "CRABCDE")
      expect(cr_bank_account).to_not be_valid
      expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
