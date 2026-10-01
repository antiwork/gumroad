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
    it "allows 10 to 14 digits" do
      expect(build(:tanzania_bank_account)).to be_valid
      expect(build(:tanzania_bank_account, account_number: "0000123456")).to be_valid
      expect(build(:tanzania_bank_account, account_number: "0000123456789")).to be_valid
      expect(build(:tanzania_bank_account, account_number: "00001234567890")).to be_valid
    end

    it "rejects the shapes Stripe's TZ rail refuses" do
      expect(build(:tanzania_bank_account, account_number: "000012345")).not_to be_valid
      expect(build(:tanzania_bank_account, account_number: "000012345678901")).not_to be_valid
      expect(build(:tanzania_bank_account, account_number: "ABC12345678")).not_to be_valid
      expect(build(:tanzania_bank_account, account_number: "0001234567ABCD")).not_to be_valid
    end

    it "names the expected format in the error" do
      na_bank_account = build(:tanzania_bank_account, account_number: "0001234567ABCD")
      na_bank_account.valid?
      expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end

    it "rejects a new row with no account number" do
      expect(build(:tanzania_bank_account, account_number: nil)).not_to be_valid
    end

    it "does not re-validate a pre-existing alphanumeric number on an unrelated save" do
      ba = build(:tanzania_bank_account, account_number: "ABC12345678")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a bad number when the number itself is being changed" do
      ba = build(:tanzania_bank_account, account_number: "ABC12345678")
      ba.save!(validate: false)

      ba.account_number = "0001234567ABCD"
      expect(ba).not_to be_valid
    end

    it "allows a pre-existing alphanumeric number to be corrected" do
      ba = build(:tanzania_bank_account, account_number: "ABC12345678")
      ba.save!(validate: false)

      ba.account_number = "0000123456789"
      expect(ba).to be_valid
    end
  end
end
