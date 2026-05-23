# frozen_string_literal: true

require "test_helper"

class MexicoBankAccountTest < ActiveSupport::TestCase
  self.described_class = MexicoBankAccount



  context_ MexicoBankAccount do
  context_ "#bank_account_type" do
  test "returns mexico" do
        expect(create(:mexico_bank_account).bank_account_type).to eq("MX")
      end
    end

  context_ "#country" do
  test "returns MX" do
        expect(create(:mexico_bank_account).country).to eq("MX")
      end
    end

  context_ "#currency" do
  test "returns mxn" do
        expect(create(:mexico_bank_account).currency).to eq("mxn")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:mexico_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:mexico_bank_account, account_number_last_four: "7897").account_number_visual).to eq("******7897")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:mexico_bank_account)).to be_valid
        expect(build(:mexico_bank_account, account_number: "000000001234567897")).to be_valid

        mx_bank_account = build(:mexico_bank_account, account_number: "MX12345")
        expect(mx_bank_account).not_to be_valid
        expect(mx_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        mx_bank_account = build(:mexico_bank_account, account_number: "DE61109010140000071219812874")
        expect(mx_bank_account).not_to be_valid
        expect(mx_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        mx_bank_account = build(:mexico_bank_account, account_number: "8937040044053201300000")
        expect(mx_bank_account).not_to be_valid
        expect(mx_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        mx_bank_account = build(:mexico_bank_account, account_number: "MXABCDE")
        expect(mx_bank_account).not_to be_valid
        expect(mx_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
