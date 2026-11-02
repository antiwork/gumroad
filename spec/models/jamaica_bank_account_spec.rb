# frozen_string_literal: true

require "spec_helper"

describe JamaicaBankAccount do
  describe "#bank_account_type" do
    it "returns JM" do
      expect(create(:jamaica_bank_account).bank_account_type).to eq("JM")
    end
  end

  describe "#country" do
    it "returns JM" do
      expect(create(:jamaica_bank_account).country).to eq("JM")
    end
  end

  describe "#currency" do
    it "returns jmd" do
      expect(create(:jamaica_bank_account).currency).to eq("jmd")
    end
  end

  describe "#bank_code" do
    it "is an alias for bank_number" do
      ba = create(:jamaica_bank_account, bank_number: "124")
      expect(ba.bank_code).to eq("124")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:jamaica_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 3 digits only" do
      expect(build(:jamaica_bank_account, bank_number: "124")).to be_valid
      expect(build(:jamaica_bank_account, bank_number: "12")).not_to be_valid
      expect(build(:jamaica_bank_account, bank_number: "1234")).not_to be_valid
      expect(build(:jamaica_bank_account, bank_number: "abc")).not_to be_valid
    end
  end

  describe "#validate_branch_code" do
    it "allows 5 digits only" do
      expect(build(:jamaica_bank_account, branch_code: "12346")).to be_valid
      expect(build(:jamaica_bank_account, branch_code: "1234")).not_to be_valid
      expect(build(:jamaica_bank_account, branch_code: "123456")).not_to be_valid
      expect(build(:jamaica_bank_account, branch_code: "abcde")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows 1 to 18 digits" do
      expect(build(:jamaica_bank_account, account_number: "1")).to be_valid
      expect(build(:jamaica_bank_account, account_number: "123456789012345678")).to be_valid
      expect(build(:jamaica_bank_account, account_number: "1234567890123456789")).not_to be_valid
      expect(build(:jamaica_bank_account, account_number: "abc")).not_to be_valid
    end
  end

  describe "#to_hash" do
    it "returns the correct hash representation" do
      ba = create(:jamaica_bank_account, bank_number: "124", branch_code: "12346", account_number_last_four: "5678")
      hash = ba.to_hash
      expect(hash[:routing_number]).to eq("124-12346")
      expect(hash[:account_number]).to eq("******5678")
      expect(hash[:bank_account_type]).to eq("JM")
    end
  end

  describe "copied example bank code" do
    it "refuses a new account with 123" do
      account = build(:jamaica_bank_account, bank_code: "123")

      expect(account).not_to be_valid
      expect(account.errors.full_messages.to_sentence).to eq("Enter the 3-digit code of your own bank.")
    end

    it "does not block saving a stored row whose bank code is unchanged" do
      account = create(:jamaica_bank_account)
      account.update_column(:bank_number, "123")

      expect(account.reload.update(account_holder_full_name: "Renamed Creator")).to be(true)
    end
  end

  describe "copied example branch code" do
    it "refuses a new account with 12345" do
      account = build(:jamaica_bank_account, branch_code: "12345")

      expect(account).not_to be_valid
      expect(account.errors.full_messages.to_sentence).to eq("Enter the 5-digit branch code of your own bank branch.")
    end

    it "does not block saving a stored row whose branch code is unchanged" do
      account = create(:jamaica_bank_account)
      account.update_column(:branch_code, "12345")

      expect(account.reload.update(account_holder_full_name: "Renamed Creator")).to be(true)
    end
  end
end
