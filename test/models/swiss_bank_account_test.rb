# frozen_string_literal: true

require "test_helper"

class SwissBankAccountTest < ActiveSupport::TestCase
  self.described_class = SwissBankAccount



  context_ SwissBankAccount do
  context_ "#bank_account_type" do
  test "returns swiss" do
        expect(create(:swiss_bank_account).bank_account_type).to eq("CH")
      end
    end

  context_ "#country" do
  test "returns CH" do
        expect(create(:swiss_bank_account).country).to eq("CH")
      end
    end

  context_ "#currency" do
  test "returns chf" do
        expect(create(:swiss_bank_account).currency).to eq("chf")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:swiss_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:swiss_bank_account, account_number_last_four: "3000").account_number_visual).to eq("CH******3000")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:swiss_bank_account)).to be_valid
        expect(build(:swiss_bank_account, account_number: "CH1234567890123456789")).to be_valid

        ch_bank_account = build(:swiss_bank_account, account_number: "CH12345")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ch_bank_account = build(:swiss_bank_account, account_number: "DE9300762011623852957")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ch_bank_account = build(:swiss_bank_account, account_number: "8937040044053201300000")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ch_bank_account = build(:swiss_bank_account, account_number: "CHABCDE")
        expect(ch_bank_account).not_to be_valid
        expect(ch_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
