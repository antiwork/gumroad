# frozen_string_literal: true

describe NigerBankAccount do
  describe "#bank_account_type" do
    it "returns NE" do
      expect(create(:niger_bank_account).bank_account_type).to eq("NE")
    end
  end

  describe "#country" do
    it "returns NE" do
      expect(create(:niger_bank_account).country).to eq("NE")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:niger_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:niger_bank_account, account_number_last_four: "0268").account_number_visual).to eq("NE******0268")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:niger_bank_account).routing_number).to be nil
    end
  end

  describe "#validate_account_number" do
    it "allows a valid 28-character NE IBAN" do
      ba = build(:niger_bank_account, account_number: "NE08NE0001234567890123456789")
      expect(ba).to be_valid
    end

    it "allows a valid NE IBAN entered with spaces and lowercase" do
      ba = build(:niger_bank_account, account_number: "ne08 ne00 0123 4567 8901 2345 6789")
      expect(ba).to be_valid
    end

    it "rejects an IBAN with invalid check digits" do
      ba = build(:niger_bank_account, account_number: "NE00NE0001234567890123456789")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an IBAN with the wrong country code" do
      ba = build(:niger_bank_account, account_number: "GB08NE0001234567890123456789")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an IBAN that is too short" do
      ba = build(:niger_bank_account, account_number: "NE08NE000123456789012345678")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects an account number with a non-digit in the account portion" do
      ba = build(:niger_bank_account, account_number: "NE08NE000123456789012345678X")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end

    it "rejects a blank account number" do
      ba = build(:niger_bank_account, account_number: "")
      expect(ba).not_to be_valid
      expect(ba.errors.full_messages).to include("The account number is invalid.")
    end
  end
end
