# frozen_string_literal: true

describe AntiguaAndBarbudaBankAccount do
  describe "#bank_account_type" do
    it "returns AG" do
      expect(create(:antigua_and_barbuda_bank_account).bank_account_type).to eq("AG")
    end
  end

  describe "#country" do
    it "returns AG" do
      expect(create(:antigua_and_barbuda_bank_account).country).to eq("AG")
    end
  end

  describe "#currency" do
    it "returns xcd" do
      expect(create(:antigua_and_barbuda_bank_account).currency).to eq("xcd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 to 11 characters" do
      expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAGXYZ")).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAG")).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAGXYZZ")).not_to be_valid
      expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGA")).not_to be_valid
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:antigua_and_barbuda_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:antigua_and_barbuda_bank_account)).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, account_number: "000123456789")).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, account_number: "00012345678910111213141516171819")).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, account_number: "ABC12345678910111213141516171819")).to be_valid
      expect(build(:antigua_and_barbuda_bank_account, account_number: "12345678910111213141516171819ABC")).to be_valid

      ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "000123456789101112131415161718192")
      expect(ag_bank_account).to_not be_valid
      expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "ABCD12345678910111213141516171819")
      expect(ag_bank_account).to_not be_valid
      expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "12345678910111213141516171819ABCD")
      expect(ag_bank_account).to_not be_valid
      expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "AB12345678910111213141516171819CD")
      expect(ag_bank_account).to_not be_valid
      expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
