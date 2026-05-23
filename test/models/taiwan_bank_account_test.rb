# frozen_string_literal: true

require "test_helper"

class TaiwanBankAccountTest < ActiveSupport::TestCase
  self.described_class = TaiwanBankAccount



  context_ TaiwanBankAccount do
  context_ "#bank_account_type" do
  test "returns Taiwan" do
        expect(create(:taiwan_bank_account).bank_account_type).to eq("TW")
      end
    end

  context_ "#country" do
  test "returns TW" do
        expect(create(:taiwan_bank_account).country).to eq("TW")
      end
    end

  context_ "#currency" do
  test "returns twd" do
        expect(create(:taiwan_bank_account).currency).to eq("twd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:taiwan_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAATWTXXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:taiwan_bank_account, account_number_last_four: "4567").account_number_visual).to eq("******4567")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:taiwan_bank_account, bank_code: "AAAATWTXXXX")).to be_valid
        expect(build(:taiwan_bank_account, bank_code: "AAAATWTX")).to be_valid
        expect(build(:taiwan_bank_account, bank_code: "AAAATWT")).not_to be_valid
        expect(build(:taiwan_bank_account, bank_code: "AAAATWTXXXXX")).not_to be_valid
      end
    end
  end
end
