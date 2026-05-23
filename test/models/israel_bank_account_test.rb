# frozen_string_literal: true

require "test_helper"

class IsraelBankAccountTest < ActiveSupport::TestCase
  self.described_class = IsraelBankAccount



  context_ IsraelBankAccount do
  context_ "#bank_account_type" do
  test "returns IL" do
        expect(create(:israel_bank_account).bank_account_type).to eq("IL")
      end
    end

  context_ "#country" do
  test "returns IL" do
        expect(create(:israel_bank_account).country).to eq("IL")
      end
    end

  context_ "#currency" do
  test "returns ils" do
        expect(create(:israel_bank_account).currency).to eq("ils")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:israel_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:israel_bank_account, account_number_last_four: "9999").account_number_visual).to eq("IL******9999")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:israel_bank_account)).to be_valid
        expect(build(:israel_bank_account, account_number: "IL62 0108 0000 0009 9999 999")).to be_valid

        il_bank_account = build(:israel_bank_account, account_number: "IL12345")
        expect(il_bank_account).not_to be_valid
        expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        il_bank_account = build(:israel_bank_account, account_number: "DE6508000000192000145399")
        expect(il_bank_account).not_to be_valid
        expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        il_bank_account = build(:israel_bank_account, account_number: "8937040044053201300000")
        expect(il_bank_account).not_to be_valid
        expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        il_bank_account = build(:israel_bank_account, account_number: "ILABCDE")
        expect(il_bank_account).not_to be_valid
        expect(il_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
