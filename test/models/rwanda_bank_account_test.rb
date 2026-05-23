# frozen_string_literal: true

require "test_helper"

class RwandaBankAccountTest < ActiveSupport::TestCase
  self.described_class = RwandaBankAccount


  context_ RwandaBankAccount do
  context_ "#bank_account_type" do
  test "returns RW" do
        expect(create(:rwanda_bank_account).bank_account_type).to eq("RW")
      end
    end

  context_ "#country" do
  test "returns RW" do
        expect(create(:rwanda_bank_account).country).to eq("RW")
      end
    end

  context_ "#currency" do
  test "returns rwf" do
        expect(create(:rwanda_bank_account).currency).to eq("rwf")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(build(:rwanda_bank_account, bank_code: "AAAARWRWXXX")).to be_valid
        expect(build(:rwanda_bank_account, bank_code: "AAAARWRW")).to be_valid
        expect(build(:rwanda_bank_account, bank_code: "AAAARWRWXXXX")).not_to be_valid
        expect(build(:rwanda_bank_account, bank_code: "AAAARWR")).not_to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:rwanda_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:rwanda_bank_account)).to be_valid
        expect(build(:rwanda_bank_account, account_number: "1")).to be_valid
        expect(build(:rwanda_bank_account, account_number: "12345")).to be_valid
        expect(build(:rwanda_bank_account, account_number: "0001234567")).to be_valid
        expect(build(:rwanda_bank_account, account_number: "123456789012345")).to be_valid
      end

  test "rejects records that do not match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        rw_bank_account = build(:rwanda_bank_account, account_number: "ABCDEF")
        expect(rw_bank_account).not_to be_valid
        expect(rw_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        rw_bank_account = build(:rwanda_bank_account, account_number: "1234567890123456")
        expect(rw_bank_account).not_to be_valid
        expect(rw_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        rw_bank_account = build(:rwanda_bank_account, account_number: "ABC000123456789")
        expect(rw_bank_account).not_to be_valid
        expect(rw_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
