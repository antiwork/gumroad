# frozen_string_literal: true

require "test_helper"

class EthiopiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = EthiopiaBankAccount


  context_ EthiopiaBankAccount do
  context_ "#bank_account_type" do
  test "returns ET" do
        expect(create(:ethiopia_bank_account).bank_account_type).to eq("ET")
      end
    end

  context_ "#country" do
  test "returns ET" do
        expect(create(:ethiopia_bank_account).country).to eq("ET")
      end
    end

  context_ "#currency" do
  test "returns etb" do
        expect(create(:ethiopia_bank_account).currency).to eq("etb")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:ethiopia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAETETXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:ethiopia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("******2345")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:ethiopia_bank_account)).to be_valid
        expect(build(:ethiopia_bank_account, account_number: "0000000012345678")).to be_valid
        expect(build(:ethiopia_bank_account, account_number: "ET00000012345678")).to be_valid

        et_bank_account = build(:ethiopia_bank_account, account_number: "000000001234")
        expect(et_bank_account).not_to be_valid
        expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        et_bank_account = build(:ethiopia_bank_account, account_number: "ET0000001234")
        expect(et_bank_account).not_to be_valid
        expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        et_bank_account = build(:ethiopia_bank_account, account_number: "00000000123456789")
        expect(et_bank_account).not_to be_valid
        expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        et_bank_account = build(:ethiopia_bank_account, account_number: "ET000000123456789")
        expect(et_bank_account).not_to be_valid
        expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
