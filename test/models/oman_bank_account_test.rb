# frozen_string_literal: true

require "test_helper"

class OmanBankAccountTest < ActiveSupport::TestCase
  self.described_class = OmanBankAccount


  context_ OmanBankAccount do
  context_ "#bank_account_type" do
  test "returns OM" do
        expect(create(:oman_bank_account).bank_account_type).to eq("OM")
      end
    end

  context_ "#country" do
  test "returns OM" do
        expect(create(:oman_bank_account).country).to eq("OM")
      end
    end

  context_ "#currency" do
  test "returns omr" do
        expect(create(:oman_bank_account).currency).to eq("omr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(create(:oman_bank_account, bank_code: "AAAAOMOM")).to be_valid
        expect(create(:oman_bank_account, bank_code: "AAAAOMOMX")).to be_valid
        expect(create(:oman_bank_account, bank_code: "AAAAOMOMXX")).to be_valid
        expect(create(:oman_bank_account, bank_code: "AAAAOMOMXXX")).to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:oman_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that are valid Omani IBANs" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:oman_bank_account, account_number: "OM030001234567890123456")).to be_valid
        expect(build(:oman_bank_account, account_number: "OM810180000001299123456")).to be_valid
      end

  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:oman_bank_account)).to be_valid
        expect(build(:oman_bank_account, account_number: "123456")).to be_valid
        expect(build(:oman_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:oman_bank_account, account_number: "1234567890123456")).to be_valid
      end

  test "rejects records that are invalid Omani IBANs" do
        allow(Rails.env).to receive(:production?).and_return(true)

        # all values are incorrect
        om_bank_account = build(:oman_bank_account, account_number: "OM000000000000000000000")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        # incorrect check digits
        om_bank_account = build(:oman_bank_account, account_number: "OM060001234567890123456")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        # incorrect country code
        om_bank_account = build(:oman_bank_account, account_number: "FR1420041010050500013M02606")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end

  test "rejects records that do not match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)
        om_bank_account = build(:oman_bank_account, account_number: "12345")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        om_bank_account = build(:oman_bank_account, account_number: "12345678901234567")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        om_bank_account = build(:oman_bank_account, account_number: "ABCDEF")
        expect(om_bank_account).not_to be_valid
        expect(om_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
