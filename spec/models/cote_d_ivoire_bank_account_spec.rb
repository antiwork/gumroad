# frozen_string_literal: true

describe CoteDIvoireBankAccount do
  describe "#bank_account_type" do
    it "returns CI" do
      expect(create(:cote_d_ivoire_bank_account).bank_account_type).to eq("CI")
    end
  end

  describe "#country" do
    it "returns CI" do
      expect(create(:cote_d_ivoire_bank_account).country).to eq("CI")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:cote_d_ivoire_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:cote_d_ivoire_bank_account, account_number_last_four: "0589").account_number_visual).to eq("CI******0589")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:cote_d_ivoire_bank_account).routing_number).to be nil
    end
  end

  describe "#validate_account_number" do
    it "allows a valid 28-character CI IBAN" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "CI73CI1231234567890123456789")
      expect(ba).to be_valid
    end

    it "allows a valid CI IBAN entered with spaces and lowercase" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "ci73 ci12 3123 4567 8901 2345 6789")
      expect(ba).to be_valid
    end

    it "rejects an IBAN with invalid check digits" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "CI00CI1231234567890123456789")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an IBAN with the wrong country code" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "GB73CI1231234567890123456789")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an IBAN that is too short" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "CI73CI123123456789012345678")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an account number with a non-digit in the account portion" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "CI73CI123123456789012345678X")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects a blank account number" do
      ba = build(:cote_d_ivoire_bank_account, account_number: "")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end
  end
end
