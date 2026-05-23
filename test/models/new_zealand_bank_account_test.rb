# frozen_string_literal: true

require "test_helper"

class NewZealandBankAccountTest < ActiveSupport::TestCase
  self.described_class = NewZealandBankAccount



  context_ NewZealandBankAccount do
  context_ "#bank_account_type" do
  test "returns new zealand" do
        expect(create(:new_zealand_bank_account).bank_account_type).to eq("NZ")
      end
    end

  context_ "#country" do
  test "returns NZ" do
        expect(create(:new_zealand_bank_account).country).to eq("NZ")
      end
    end

  context_ "#currency" do
  test "returns nzd" do
        expect(create(:new_zealand_bank_account).currency).to eq("nzd")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:new_zealand_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:new_zealand_bank_account, account_number_last_four: "0010").account_number_visual).to eq("******0010")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:new_zealand_bank_account, account_number: "1100000000000010")).to be_valid
        expect(build(:new_zealand_bank_account, account_number: "1123456789012345")).to be_valid
        expect(build(:new_zealand_bank_account, account_number: "112345678901234")).to be_valid

        ch_bank_account = build(:new_zealand_bank_account, account_number: "NZ12345")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ch_bank_account = build(:new_zealand_bank_account, account_number: "11000000000000")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ch_bank_account = build(:new_zealand_bank_account, account_number: "CHABCDEFGHIJKLMNZ")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
