# frozen_string_literal: true

require "test_helper"

class ParaguayBankAccountTest < ActiveSupport::TestCase
  self.described_class = ParaguayBankAccount



  context_ ParaguayBankAccount do
  context_ "#bank_account_type" do
  test "returns PY" do
        expect(create(:paraguay_bank_account).bank_account_type).to eq("PY")
      end
    end

  context_ "#country" do
  test "returns PY" do
        expect(create(:paraguay_bank_account).country).to eq("PY")
      end
    end

  context_ "#currency" do
  test "returns pyg" do
        expect(create(:paraguay_bank_account).currency).to eq("pyg")
      end
    end

  context_ "#bank_code" do
  test "returns valid for 1 to 2 characters" do
        expect(create(:paraguay_bank_account, bank_code: "12")).to be_valid
        expect(create(:paraguay_bank_account, bank_code: "1")).to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:paraguay_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:paraguay_bank_account)).to be_valid
        expect(build(:paraguay_bank_account, account_number: "1234567890123456")).to be_valid
        expect(build(:paraguay_bank_account, account_number: "123")).to be_valid

        py_bank_account = build(:paraguay_bank_account, account_number: "12345678901234567")
        expect(py_bank_account).not_to be_valid
        expect(py_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        py_bank_account = build(:paraguay_bank_account, account_number: "ABC123")
        expect(py_bank_account).not_to be_valid
        expect(py_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
