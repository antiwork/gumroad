# frozen_string_literal: true

require "test_helper"

class CambodiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = CambodiaBankAccount



  context_ CambodiaBankAccount do
  context_ "#bank_account_type" do
  test "returns KH" do
        expect(create(:cambodia_bank_account).bank_account_type).to eq("KH")
      end
    end

  context_ "#country" do
  test "returns KH" do
        expect(create(:cambodia_bank_account).country).to eq("KH")
      end
    end

  context_ "#currency" do
  test "returns khr" do
        expect(create(:cambodia_bank_account).currency).to eq("khr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:cambodia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAKHKHXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        bank_account = create(:cambodia_bank_account, account_number: "000123456789", account_number_last_four: "6789")
        expect(bank_account.account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:cambodia_bank_account, bank_code: "AAAAKHKHXXX")).to be_valid
        expect(build(:cambodia_bank_account, bank_code: "AAAAKHKH")).to be_valid
        expect(build(:cambodia_bank_account, bank_code: "AAAAKHKHXXXX")).not_to be_valid
        expect(build(:cambodia_bank_account, bank_code: "AAAAKHK")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
      let(:bank_account) { build(:cambodia_bank_account) }

  test "validates account number format" do
        bank_account.account_number = "000123456789"
        bank_account.account_number_last_four = "6789"
        expect(bank_account).to be_valid

        bank_account.account_number = "00012"
        bank_account.account_number_last_four = "0012"
        expect(bank_account).to be_valid

        bank_account.account_number = "1234"
        bank_account.account_number_last_four = "1234"
        expect(bank_account).not_to be_valid

        bank_account.account_number = "1234567890123456"
        bank_account.account_number_last_four = "3456"
        expect(bank_account).not_to be_valid
      end
    end
  end
end
