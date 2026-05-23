# frozen_string_literal: true

require "test_helper"

class VietnamBankAccountTest < ActiveSupport::TestCase
  self.described_class = VietnamBankAccount



  context_ VietnamBankAccount do
  context_ "#bank_account_type" do
  test "returns Vietnam" do
        expect(create(:vietnam_bank_account).bank_account_type).to eq("VN")
      end
    end

  context_ "#country" do
  test "returns VN" do
        expect(create(:vietnam_bank_account).country).to eq("VN")
      end
    end

  context_ "#currency" do
  test "returns vnd" do
        expect(create(:vietnam_bank_account).currency).to eq("vnd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 characters" do
        ba = create(:vietnam_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("01101100")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:vietnam_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 numbers only" do
        expect(build(:vietnam_bank_account, bank_code: "01101100")).to be_valid
        expect(build(:vietnam_bank_account, bank_code: "AAAATWTX")).not_to be_valid
        expect(build(:vietnam_bank_account, bank_code: "0110110")).not_to be_valid
        expect(build(:vietnam_bank_account, bank_code: "011011000")).not_to be_valid
      end
    end
  end
end
