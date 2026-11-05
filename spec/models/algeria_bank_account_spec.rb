# frozen_string_literal: true

describe AlgeriaBankAccount do
  describe "#bank_account_type" do
    it "returns DZ" do
      expect(create(:algeria_bank_account).bank_account_type).to eq("DZ")
    end
  end

  describe "#country" do
    it "returns DZ" do
      expect(create(:algeria_bank_account).country).to eq("DZ")
    end
  end

  describe "#currency" do
    it "returns dzd" do
      expect(create(:algeria_bank_account).currency).to eq("dzd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:algeria_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAADZDZXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:algeria_bank_account, account_number_last_four: "1234").account_number_visual).to eq("******1234")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      # Valid account number (success case)
      expect(build(:algeria_bank_account)).to be_valid
      expect(build(:algeria_bank_account, account_number: "00001234567890123456")).to be_valid

      # Test error cases from Stripe docs
      expect(build(:algeria_bank_account, account_number: "00001001001111111116")).to be_valid  # no_account
      expect(build(:algeria_bank_account, account_number: "00001001001111111113")).to be_valid  # account_closed
      expect(build(:algeria_bank_account, account_number: "00001001002222222227")).to be_valid  # insufficient_funds
      expect(build(:algeria_bank_account, account_number: "00001001003333333335")).to be_valid  # debit_not_authorized
      expect(build(:algeria_bank_account, account_number: "00001001004444444440")).to be_valid  # invalid_currency

      # Invalid format tests
      dz_bank_account = build(:algeria_bank_account, account_number: "12345")  # too short
      expect(dz_bank_account).not_to be_valid
      expect(dz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      dz_bank_account = build(:algeria_bank_account, account_number: "123456789012345678901")  # too long
      expect(dz_bank_account).not_to be_valid
      expect(dz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      dz_bank_account = build(:algeria_bank_account, account_number: "ABCD12345678901234XX")  # contains letters
      expect(dz_bank_account).not_to be_valid
      expect(dz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
