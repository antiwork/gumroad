# frozen_string_literal: true

require "test_helper"

class NorwayBankAccountTest < ActiveSupport::TestCase
  self.described_class = NorwayBankAccount



  context_ NorwayBankAccount do
  context_ "#bank_account_type" do
  test "returns NO" do
        expect(create(:norway_bank_account).bank_account_type).to eq("NO")
      end
    end

  context_ "#country" do
  test "returns NO" do
        expect(create(:norway_bank_account).country).to eq("NO")
      end
    end

  context_ "#currency" do
  test "returns nok" do
        expect(create(:norway_bank_account).currency).to eq("nok")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:norway_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:norway_bank_account, account_number_last_four: "7947").account_number_visual).to eq("******7947")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:norway_bank_account)).to be_valid
        expect(build(:norway_bank_account, account_number: "NO9386011117947")).to be_valid

        no_bank_account = build(:norway_bank_account, account_number: "NO938601111")
        expect(no_bank_account).not_to be_valid
        expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        no_bank_account = build(:norway_bank_account, account_number: "NOABCDEFGHIJKLM")
        expect(no_bank_account).not_to be_valid
        expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        no_bank_account = build(:norway_bank_account, account_number: "NO9386011117947123")
        expect(no_bank_account).not_to be_valid
        expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        no_bank_account = build(:norway_bank_account, account_number: "129386011117947")
        expect(no_bank_account).not_to be_valid
        expect(no_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
