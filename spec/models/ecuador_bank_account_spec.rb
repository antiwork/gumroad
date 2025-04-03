# frozen_string_literal: true

describe EcuadorBankAccount do
  describe "#bank_account_type" do
    it "returns EC" do
      expect(create(:ecuador_bank_account).bank_account_type).to eq("EC")
    end
  end

  describe "#country" do
    it "returns EC" do
      expect(create(:ecuador_bank_account).country).to eq("EC")
    end
  end

  describe "#currency" do
    it "returns usd" do
      expect(create(:ecuador_bank_account).currency).to eq("usd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 to 11 characters" do
      expect(create(:ecuador_bank_account, bank_code: "AAAAECE1")).to be_valid
      expect(create(:ecuador_bank_account, bank_code: "AAAAECE1X")).to be_valid
      expect(create(:ecuador_bank_account, bank_code: "AAAAECE1XX")).to be_valid
      expect(create(:ecuador_bank_account, bank_code: "AAAAECE1XXX")).to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:ecuador_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:ecuador_bank_account)).to be_valid
      expect(build(:ecuador_bank_account, account_number: "000123456789")).to be_valid
      expect(build(:ecuador_bank_account, account_number: "00012")).to be_valid
      expect(build(:ecuador_bank_account, account_number: "000123456789101112")).to be_valid

      ec_bank_account = build(:ecuador_bank_account, account_number: "EC12345")
      expect(ec_bank_account).to_not be_valid
      expect(ec_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ec_bank_account = build(:ecuador_bank_account, account_number: "EC61109010140000071219812874")
      expect(ec_bank_account).to_not be_valid
      expect(ec_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ec_bank_account = build(:ecuador_bank_account, account_number: "8937040044053201300")
      expect(ec_bank_account).to_not be_valid
      expect(ec_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ec_bank_account = build(:ecuador_bank_account, account_number: "CRABCDE")
      expect(ec_bank_account).to_not be_valid
      expect(ec_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
