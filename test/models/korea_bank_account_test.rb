# frozen_string_literal: true

require "test_helper"

class KoreaBankAccountTest < ActiveSupport::TestCase
  self.described_class = KoreaBankAccount



  context_ KoreaBankAccount do
  context_ "#bank_account_type" do
  test "returns korea" do
        expect(create(:korea_bank_account).bank_account_type).to eq("KR")
      end
    end

  context_ "#country" do
  test "returns KR" do
        expect(create(:korea_bank_account).country).to eq("KR")
      end
    end

  context_ "#currency" do
  test "returns krw" do
        expect(create(:korea_bank_account).currency).to eq("krw")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 digits" do
        ba = create(:korea_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("SGSEKRSLXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:korea_bank_account, account_number_last_four: "8912").account_number_visual).to eq("******8912")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:korea_bank_account, bank_code: "TESTKR00")).to be_valid
        expect(build(:korea_bank_account, bank_code: "BANKKR001")).to be_valid
        expect(build(:korea_bank_account, bank_code: "CASHKR00123")).to be_valid

        expect(build(:korea_bank_account, bank_code: "ABCD")).not_to be_valid
        expect(build(:korea_bank_account, bank_code: "1234")).not_to be_valid
        expect(build(:korea_bank_account, bank_code: "TESTKR0")).not_to be_valid
        expect(build(:korea_bank_account, bank_code: "TESTKR001234")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:korea_bank_account, account_number: "00123456789")).to be_valid
        expect(build(:korea_bank_account, account_number: "0000123456789")).to be_valid
        expect(build(:korea_bank_account, account_number: "000000123456789")).to be_valid

        kr_bank_account = build(:korea_bank_account, account_number: "ABCDEFGHIJKL")
        expect(kr_bank_account).not_to be_valid
        expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        kr_bank_account = build(:korea_bank_account, account_number: "8937040044053201300000")
        expect(kr_bank_account).not_to be_valid
        expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        kr_bank_account = build(:korea_bank_account, account_number: "12345")
        expect(kr_bank_account).not_to be_valid
        expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
