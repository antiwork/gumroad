# frozen_string_literal: true

require "test_helper"

class CzechRepublicBankAccountTest < ActiveSupport::TestCase
  self.described_class = CzechRepublicBankAccount



  context_ CzechRepublicBankAccount do
  context_ "#bank_account_type" do
  test "returns CZ" do
        expect(create(:czech_republic_bank_account).bank_account_type).to eq("CZ")
      end
    end

  context_ "#country" do
  test "returns CZ" do
        expect(create(:czech_republic_bank_account).country).to eq("CZ")
      end
    end

  context_ "#currency" do
  test "returns czk" do
        expect(create(:czech_republic_bank_account).currency).to eq("czk")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:czech_republic_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:czech_republic_bank_account, account_number_last_four: "3000").account_number_visual).to eq("CZ******3000")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:czech_republic_bank_account)).to be_valid
        expect(build(:czech_republic_bank_account, account_number: "CZ65 0800 0000 1920 0014 5399")).to be_valid

        cz_bank_account = build(:czech_republic_bank_account, account_number: "CZ12345")
        expect(cz_bank_account).not_to be_valid
        expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cz_bank_account = build(:czech_republic_bank_account, account_number: "DE6508000000192000145399")
        expect(cz_bank_account).not_to be_valid
        expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cz_bank_account = build(:czech_republic_bank_account, account_number: "8937040044053201300000")
        expect(cz_bank_account).not_to be_valid
        expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cz_bank_account = build(:czech_republic_bank_account, account_number: "CZABCDE")
        expect(cz_bank_account).not_to be_valid
        expect(cz_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
