# frozen_string_literal: true

require "test_helper"

class MalaysiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = MalaysiaBankAccount


  context_ MalaysiaBankAccount do
  context_ "#bank_account_type" do
  test "returns MY" do
        expect(create(:malaysia_bank_account).bank_account_type).to eq("MY")
      end
    end

  context_ "#country" do
  test "returns MY" do
        expect(create(:malaysia_bank_account).country).to eq("MY")
      end
    end

  context_ "#currency" do
  test "returns myr" do
        expect(create(:malaysia_bank_account).currency).to eq("myr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:malaysia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("HBMBMYKL")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:malaysia_bank_account, account_number_last_four: "6000").account_number_visual).to eq("******6000")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:malaysia_bank_account)).to be_valid
        expect(build(:malaysia_bank_account, account_number: "00012345678910111")).to be_valid
        expect(build(:malaysia_bank_account, account_number: "00012")).to be_valid

        ma_bank_account = build(:malaysia_bank_account, account_number: "MA123")
        expect(ma_bank_account).not_to be_valid
        expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ma_bank_account = build(:malaysia_bank_account, account_number: "MY123456789101112")
        expect(ma_bank_account).not_to be_valid
        expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ma_bank_account = build(:malaysia_bank_account, account_number: "000123456789101112")
        expect(ma_bank_account).not_to be_valid
        expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ma_bank_account = build(:malaysia_bank_account, account_number: "CRABC")
        expect(ma_bank_account).not_to be_valid
        expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
