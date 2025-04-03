# frozen_string_literal: true

describe TanzaniaBankAccount do
  describe "#bank_account_type" do
    it "returns TZ" do
      expect(create(:tanzania_bank_account).bank_account_type).to eq("TZ")
    end
  end

  describe "#country" do
    it "returns TZ" do
      expect(create(:tanzania_bank_account).country).to eq("TZ")
    end
  end

  describe "#currency" do
    it "returns tzs" do
      expect(create(:tanzania_bank_account).currency).to eq("tzs")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 to 11 characters" do
      expect(build(:tanzania_bank_account, bank_code: "AAAATZTXXXX")).to be_valid
      expect(build(:tanzania_bank_account, bank_code: "AAAATZTX")).to be_valid
      expect(build(:tanzania_bank_account, bank_code: "AAAATZTXXXXX")).not_to be_valid
      expect(build(:tanzania_bank_account, bank_code: "AAAATZT")).not_to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:tanzania_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:tanzania_bank_account)).to be_valid
      expect(build(:tanzania_bank_account, account_number: "0000123456789")).to be_valid
      expect(build(:tanzania_bank_account, account_number: "0000123456")).to be_valid
      expect(build(:tanzania_bank_account, account_number: "ABC12345678")).to be_valid
      expect(build(:tanzania_bank_account, account_number: "0001234567ABCD")).to be_valid

      na_bank_account = build(:tanzania_bank_account, account_number: "000012345")
      expect(na_bank_account).to_not be_valid
      expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      na_bank_account = build(:tanzania_bank_account, account_number: "000012345678910")
      expect(na_bank_account).to_not be_valid
      expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      na_bank_account = build(:tanzania_bank_account, account_number: "0001234567ABCDE")
      expect(na_bank_account).to_not be_valid
      expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      na_bank_account = build(:tanzania_bank_account, account_number: "ABCDE0001234567")
      expect(na_bank_account).to_not be_valid
      expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
