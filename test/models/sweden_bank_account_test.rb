# frozen_string_literal: true

require "test_helper"

class SwedenBankAccountTest < ActiveSupport::TestCase
  self.described_class = SwedenBankAccount



  context_ SwedenBankAccount do
  context_ "#bank_account_type" do
  test "returns sweden" do
        expect(create(:sweden_bank_account).bank_account_type).to eq("SE")
      end
    end

  context_ "#country" do
  test "returns SE" do
        expect(create(:sweden_bank_account).country).to eq("SE")
      end
    end

  context_ "#currency" do
  test "returns sek" do
        expect(create(:sweden_bank_account).currency).to eq("sek")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:sweden_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:sweden_bank_account, account_number_last_four: "0003").account_number_visual).to eq("SE******0003")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:sweden_bank_account)).to be_valid
        expect(build(:sweden_bank_account, account_number: "SE35 5000 0000 0549 1000 0003")).to be_valid

        se_bank_account = build(:sweden_bank_account, account_number: "SE12345")
        expect(se_bank_account).not_to be_valid
        expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        se_bank_account = build(:sweden_bank_account, account_number: "DE61109010140000071219812874")
        expect(se_bank_account).not_to be_valid
        expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        se_bank_account = build(:sweden_bank_account, account_number: "8937040044053201300000")
        expect(se_bank_account).not_to be_valid
        expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        se_bank_account = build(:sweden_bank_account, account_number: "SEABCDE")
        expect(se_bank_account).not_to be_valid
        expect(se_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
