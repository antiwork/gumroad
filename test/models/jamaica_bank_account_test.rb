# frozen_string_literal: true

require "test_helper"

class JamaicaBankAccountTest < ActiveSupport::TestCase
  self.described_class = JamaicaBankAccount



  context_ JamaicaBankAccount do
  context_ "#bank_account_type" do
  test "returns JM" do
        expect(create(:jamaica_bank_account).bank_account_type).to eq("JM")
      end
    end

  context_ "#country" do
  test "returns JM" do
        expect(create(:jamaica_bank_account).country).to eq("JM")
      end
    end

  context_ "#currency" do
  test "returns jmd" do
        expect(create(:jamaica_bank_account).currency).to eq("jmd")
      end
    end

  context_ "#bank_code" do
  test "is an alias for bank_number" do
        ba = create(:jamaica_bank_account, bank_number: "123")
        expect(ba.bank_code).to eq("123")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:jamaica_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 3 digits only" do
        expect(build(:jamaica_bank_account, bank_number: "123")).to be_valid
        expect(build(:jamaica_bank_account, bank_number: "12")).not_to be_valid
        expect(build(:jamaica_bank_account, bank_number: "1234")).not_to be_valid
        expect(build(:jamaica_bank_account, bank_number: "abc")).not_to be_valid
      end
    end

  context_ "#validate_branch_code" do
  test "allows 5 digits only" do
        expect(build(:jamaica_bank_account, branch_code: "12345")).to be_valid
        expect(build(:jamaica_bank_account, branch_code: "1234")).not_to be_valid
        expect(build(:jamaica_bank_account, branch_code: "123456")).not_to be_valid
        expect(build(:jamaica_bank_account, branch_code: "abcde")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows 1 to 18 digits" do
        expect(build(:jamaica_bank_account, account_number: "1")).to be_valid
        expect(build(:jamaica_bank_account, account_number: "123456789012345678")).to be_valid
        expect(build(:jamaica_bank_account, account_number: "1234567890123456789")).not_to be_valid
        expect(build(:jamaica_bank_account, account_number: "abc")).not_to be_valid
      end
    end

  context_ "#to_hash" do
  test "returns the correct hash representation" do
        ba = create(:jamaica_bank_account, bank_number: "123", branch_code: "12345", account_number_last_four: "5678")
        hash = ba.to_hash
        expect(hash[:routing_number]).to eq("123-12345")
        expect(hash[:account_number]).to eq("******5678")
        expect(hash[:bank_account_type]).to eq("JM")
      end
    end
  end
end
