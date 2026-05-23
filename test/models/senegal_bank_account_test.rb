# frozen_string_literal: true

require "test_helper"

class SenegalBankAccountTest < ActiveSupport::TestCase
  self.described_class = SenegalBankAccount



  context_ SenegalBankAccount do
  context_ "#bank_account_type" do
  test "returns senegal" do
        expect(create(:senegal_bank_account).bank_account_type).to eq("SN")
      end
    end

  context_ "#country" do
  test "returns SN" do
        expect(create(:senegal_bank_account).country).to eq("SN")
      end
    end

  context_ "#currency" do
  test "returns xof" do
        expect(create(:senegal_bank_account).currency).to eq("xof")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:senegal_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:senegal_bank_account, account_number_last_four: "3035").account_number_visual).to eq("******3035")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:senegal_bank_account)).to be_valid
        expect(build(:senegal_bank_account, account_number: "SN08SN0100152000048500003035")).to be_valid
        expect(build(:senegal_bank_account, account_number: "SN62370400440532013001")).to be_valid

        sn_bank_account = build(:senegal_bank_account, account_number: "012345678")
        expect(sn_bank_account).not_to be_valid
        expect(sn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        sn_bank_account = build(:senegal_bank_account, account_number: "ABCDEFGHIJKLMNOPQRSTUV")
        expect(sn_bank_account).not_to be_valid
        expect(sn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        sn_bank_account = build(:senegal_bank_account, account_number: "SN08SN01001520000485000030355")
        expect(sn_bank_account).not_to be_valid
        expect(sn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        sn_bank_account = build(:senegal_bank_account, account_number: "SN08SN010015200004850")
        expect(sn_bank_account).not_to be_valid
        expect(sn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
