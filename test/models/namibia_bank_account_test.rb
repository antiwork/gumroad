# frozen_string_literal: true

require "test_helper"

class NamibiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = NamibiaBankAccount


  context_ NamibiaBankAccount do
  context_ "#bank_account_type" do
  test "returns NA" do
        expect(create(:namibia_bank_account).bank_account_type).to eq("NA")
      end
    end

  context_ "#country" do
  test "returns NA" do
        expect(create(:namibia_bank_account).country).to eq("NA")
      end
    end

  context_ "#currency" do
  test "returns nad" do
        expect(create(:namibia_bank_account).currency).to eq("nad")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(build(:namibia_bank_account, bank_code: "AAAANANXXYZ")).to be_valid
        expect(build(:namibia_bank_account, bank_code: "AAAANANX")).to be_valid
        expect(build(:namibia_bank_account, bank_code: "AAAANANXXYZZ")).not_to be_valid
        expect(build(:namibia_bank_account, bank_code: "AAAANAN")).not_to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:namibia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:namibia_bank_account)).to be_valid
        expect(build(:namibia_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:namibia_bank_account, account_number: "12345678")).to be_valid
        expect(build(:namibia_bank_account, account_number: "NAM45678")).to be_valid
        expect(build(:namibia_bank_account, account_number: "0001234567NAM")).to be_valid

        na_bank_account = build(:namibia_bank_account, account_number: "1234567")
        expect(na_bank_account).not_to be_valid
        expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        na_bank_account = build(:namibia_bank_account, account_number: "12345678910111")
        expect(na_bank_account).not_to be_valid
        expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        na_bank_account = build(:namibia_bank_account, account_number: "0001234567NAMI")
        expect(na_bank_account).not_to be_valid
        expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        na_bank_account = build(:namibia_bank_account, account_number: "1234NAM")
        expect(na_bank_account).not_to be_valid
        expect(na_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
