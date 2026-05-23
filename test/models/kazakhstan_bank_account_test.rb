# frozen_string_literal: true

require "test_helper"

class KazakhstanBankAccountTest < ActiveSupport::TestCase
  self.described_class = KazakhstanBankAccount


  context_ KazakhstanBankAccount do
  context_ "#bank_account_type" do
  test "returns KZ" do
        expect(create(:kazakhstan_bank_account).bank_account_type).to eq("KZ")
      end
    end

  context_ "#country" do
  test "returns KZ" do
        expect(create(:kazakhstan_bank_account).country).to eq("KZ")
      end
    end

  context_ "#currency" do
  test "returns kzt" do
        expect(create(:kazakhstan_bank_account).currency).to eq("kzt")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZ")).to be_valid
        expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZX")).to be_valid
        expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZXX")).to be_valid
        expect(create(:kazakhstan_bank_account, bank_code: "AAAAKZKZXXX")).to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:kazakhstan_bank_account, account_number_last_four: "0123").account_number_visual).to eq("KZ******0123")
      end
    end
  end
end
