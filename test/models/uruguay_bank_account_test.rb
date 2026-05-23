# frozen_string_literal: true

require "test_helper"

class UruguayBankAccountTest < ActiveSupport::TestCase
  self.described_class = UruguayBankAccount



  context_ UruguayBankAccount do
  context_ "#bank_account_type" do
  test "returns UY" do
        expect(create(:uruguay_bank_account).bank_account_type).to eq("UY")
      end
    end

  context_ "#country" do
  test "returns UY" do
        expect(create(:uruguay_bank_account).country).to eq("UY")
      end
    end

  context_ "#currency" do
  test "returns uyu" do
        expect(create(:uruguay_bank_account).currency).to eq(Currency::UYU)
      end
    end

  context_ "#bank_code" do
  test "returns valid for 3 digits" do
        expect(build(:uruguay_bank_account, bank_number: "123")).to be_valid
        expect(build(:uruguay_bank_account, bank_number: "12")).not_to be_valid
        expect(build(:uruguay_bank_account, bank_number: "1234")).not_to be_valid
        expect(build(:uruguay_bank_account, bank_number: "abc")).not_to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:uruguay_bank_account).account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows 1 to 18 digits" do
        expect(build(:uruguay_bank_account, account_number: "1")).to be_valid
        expect(build(:uruguay_bank_account, account_number: "123456789101")).to be_valid
        expect(build(:uruguay_bank_account, account_number: "1234567891011")).not_to be_valid
        expect(build(:uruguay_bank_account, account_number: "abc")).not_to be_valid
      end
    end
  end
end
