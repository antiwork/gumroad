# frozen_string_literal: true

describe EthiopiaBankAccount do
  describe "#bank_account_type" do
    it "returns ET" do
      expect(create(:ethiopia_bank_account).bank_account_type).to eq("ET")
    end
  end

  describe "#country" do
    it "returns ET" do
      expect(create(:ethiopia_bank_account).country).to eq("ET")
    end
  end

  describe "#currency" do
    it "returns etb" do
      expect(create(:ethiopia_bank_account).currency).to eq("etb")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:ethiopia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAETETXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:ethiopia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("******2345")
    end
  end

  describe "#validate_account_number" do
    it "allows 13 to 16 digits" do
      expect(build(:ethiopia_bank_account)).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0000000012345")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "00000000123456")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "000000001234567")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0000000012345678")).to be_valid
    end

    it "rejects the shapes Stripe's ET rail refuses" do
      expect(build(:ethiopia_bank_account, account_number: "000000001234")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "00000000123456789")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "ET00000012345678")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0001234567ABCD")).not_to be_valid
    end

    it "names the expected format in the error" do
      et_bank_account = build(:ethiopia_bank_account, account_number: "0001234567ABCD")
      et_bank_account.valid?
      expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end

    it "rejects a new row with no account number" do
      expect(build(:ethiopia_bank_account, account_number: nil)).not_to be_valid
    end

    it "does not re-validate a pre-existing alphanumeric number on an unrelated save" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a bad number when the number itself is being changed" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      ba.account_number = "0001234567ABCD"
      expect(ba).not_to be_valid
    end

    it "allows a pre-existing alphanumeric number to be corrected" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      ba.account_number = "0000000012345"
      expect(ba).to be_valid
    end
  end
end
