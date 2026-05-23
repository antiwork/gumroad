# frozen_string_literal: true

require "test_helper"

class PeruBankAccountTest < ActiveSupport::TestCase
  self.described_class = PeruBankAccount



  context_ PeruBankAccount do
  context_ "#bank_account_type" do
  test "returns peru" do
        expect(create(:peru_bank_account).bank_account_type).to eq("PE")
      end
    end

  context_ "#country" do
  test "returns PE" do
        expect(create(:peru_bank_account).country).to eq("PE")
      end
    end

  context_ "#currency" do
  test "returns pen" do
        expect(create(:peru_bank_account).currency).to eq("pen")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:peru_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:peru_bank_account, account_number_last_four: "2874").account_number_visual).to eq("******2874")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:peru_bank_account)).to be_valid
        expect(build(:peru_bank_account, account_number: "01234567898765432101")).to be_valid

        pe_bank_account = build(:peru_bank_account, account_number: "012345678")
        expect(pe_bank_account).not_to be_valid
        expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pe_bank_account = build(:peru_bank_account, account_number: "ABCDEFGHIJKLMNOPQRSTUV")
        expect(pe_bank_account).not_to be_valid
        expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pe_bank_account = build(:peru_bank_account, account_number: "01234567898765432123456")
        expect(pe_bank_account).not_to be_valid
        expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pe_bank_account = build(:peru_bank_account, account_number: "012345678987654321234")
        expect(pe_bank_account).not_to be_valid
        expect(pe_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
