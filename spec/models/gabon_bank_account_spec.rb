# frozen_string_literal: true

describe GabonBankAccount do
  describe "#bank_account_type" do
    it "returns GA" do
      expect(create(:gabon_bank_account).bank_account_type).to eq("GA")
    end
  end

  describe "#country" do
    it "returns GA" do
      expect(create(:gabon_bank_account).country).to eq("GA")
    end
  end

  describe "#currency" do
    it "returns xaf" do
      expect(create(:gabon_bank_account).currency).to eq("xaf")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:gabon_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAGAGAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:gabon_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 or 11 characters only" do
      expect(build(:gabon_bank_account, bank_number: "AAAAGAGA")).to be_valid      # 8 chars
      expect(build(:gabon_bank_account, bank_number: "AAAAGAGAXXX")).to be_valid   # 11 chars
      expect(build(:gabon_bank_account, bank_number: "AAAAGAG")).not_to be_valid  # too short
      expect(build(:gabon_bank_account, bank_number: "AAAAGAGAXXXX")).not_to be_valid  # too long
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:gabon_bank_account)).to be_valid
      expect(build(:gabon_bank_account, account_number: "00012345678910111121314")).to be_valid

      ga_bank_account = build(:gabon_bank_account, account_number: "GA012345678910111121314")
      expect(ga_bank_account).to_not be_valid
      expect(ga_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ga_bank_account = build(:gabon_bank_account, account_number: "0000123456789012345678")
      expect(ga_bank_account).to_not be_valid
      expect(ga_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ga_bank_account = build(:gabon_bank_account, account_number: "000012345678901234567890")
      expect(ga_bank_account).to_not be_valid
      expect(ga_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
