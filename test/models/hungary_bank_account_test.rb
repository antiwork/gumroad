# frozen_string_literal: true

require "test_helper"

class HungaryBankAccountTest < ActiveSupport::TestCase
  self.described_class = HungaryBankAccount



  context_ HungaryBankAccount do
  context_ "#bank_account_type" do
  test "returns hungary" do
        expect(create(:hungary_bank_account).bank_account_type).to eq("HU")
      end
    end

  context_ "#country" do
  test "returns HU" do
        expect(create(:hungary_bank_account).country).to eq("HU")
      end
    end

  context_ "#currency" do
  test "returns huf" do
        expect(create(:hungary_bank_account).currency).to eq("huf")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:hungary_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:hungary_bank_account, account_number_last_four: "2874").account_number_visual).to eq("HU******2874")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:hungary_bank_account)).to be_valid
        expect(build(:hungary_bank_account, account_number: "HU42 1177 3016 1111 1018 0000 0000")).to be_valid

        hu_bank_account = build(:hungary_bank_account, account_number: "HU12345")
        expect(hu_bank_account).not_to be_valid
        expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        hu_bank_account = build(:hungary_bank_account, account_number: "DE61109010140000071219812874")
        expect(hu_bank_account).not_to be_valid
        expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        hu_bank_account = build(:hungary_bank_account, account_number: "8937040044053201300000")
        expect(hu_bank_account).not_to be_valid
        expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        hu_bank_account = build(:hungary_bank_account, account_number: "HUABCDE")
        expect(hu_bank_account).not_to be_valid
        expect(hu_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
