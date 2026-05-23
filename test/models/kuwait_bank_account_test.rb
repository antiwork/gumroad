# frozen_string_literal: true

require "test_helper"

class KuwaitBankAccountTest < ActiveSupport::TestCase
  self.described_class = KuwaitBankAccount



  context_ KuwaitBankAccount do
  context_ "#bank_account_type" do
  test "returns KW" do
        expect(create(:kuwait_bank_account).bank_account_type).to eq("KW")
      end
    end

  context_ "#country" do
  test "returns KW" do
        expect(create(:kuwait_bank_account).country).to eq("KW")
      end
    end

  context_ "#currency" do
  test "returns kwd" do
        expect(create(:kuwait_bank_account).currency).to eq("kwd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 10 characters" do
        ba = create(:kuwait_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAKWKWXYZ")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:kuwait_bank_account, account_number_last_four: "0101").account_number_visual).to eq("******0101")
      end
    end

  context_ "#validate_bank_code" do
  test "allows only 8 to 11 characters" do
        expect(build(:kuwait_bank_account, bank_code: "AAAAKWKWXYZ")).to be_valid
        expect(build(:kuwait_bank_account, bank_code: "AAA0000X")).to be_valid
        expect(build(:kuwait_bank_account, bank_code: "AAAA0000XXXX")).not_to be_valid
        expect(build(:kuwait_bank_account, bank_code: "AAAA000")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows only 30 characters in the correct format" do
        expect(build(:kuwait_bank_account, account_number: "KW81CBKU0000000000001234560101")).to be_valid
        expect(build(:kuwait_bank_account, account_number: "KW81CBKU00000000000012345601012")).not_to be_valid
        expect(build(:kuwait_bank_account, account_number: "KW81CBKU000000000000123456")).not_to be_valid
        expect(build(:kuwait_bank_account, account_number: "KW81CBKU0000000000001234560101234")).not_to be_valid
      end
    end
  end
end
