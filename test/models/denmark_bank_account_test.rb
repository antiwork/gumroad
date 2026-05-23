# frozen_string_literal: true

require "test_helper"

class DenmarkBankAccountTest < ActiveSupport::TestCase
  self.described_class = DenmarkBankAccount



  context_ DenmarkBankAccount do
  context_ "#bank_account_type" do
  test "returns denmark" do
        expect(create(:denmark_bank_account).bank_account_type).to eq("DK")
      end
    end

  context_ "#country" do
  test "returns DK" do
        expect(create(:denmark_bank_account).country).to eq("DK")
      end
    end

  context_ "#currency" do
  test "returns dkn" do
        expect(create(:denmark_bank_account).currency).to eq("dkk")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:denmark_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:denmark_bank_account, account_number_last_four: "2874").account_number_visual).to eq("DK******2874")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:denmark_bank_account)).to be_valid
        expect(build(:denmark_bank_account, account_number: "DK 5000 4004 4011 6243")).to be_valid

        dk_bank_account = build(:denmark_bank_account, account_number: "DK12345")
        expect(dk_bank_account).not_to be_valid
        expect(dk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        dk_bank_account = build(:denmark_bank_account, account_number: "DE61109010140000071219812874")
        expect(dk_bank_account).not_to be_valid
        expect(dk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        dk_bank_account = build(:denmark_bank_account, account_number: "8937040044053201300000")
        expect(dk_bank_account).not_to be_valid
        expect(dk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        dk_bank_account = build(:denmark_bank_account, account_number: "DKABCDE")
        expect(dk_bank_account).not_to be_valid
        expect(dk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
