# frozen_string_literal: true

require "test_helper"

class BeninBankAccountTest < ActiveSupport::TestCase
  self.described_class = BeninBankAccount


  context_ BeninBankAccount do
  context_ "#bank_account_type" do
  test "returns BJ" do
        expect(create(:benin_bank_account).bank_account_type).to eq("BJ")
      end
    end

  context_ "#country" do
  test "returns BJ" do
        expect(create(:benin_bank_account).country).to eq("BJ")
      end
    end

  context_ "#currency" do
  test "returns xof" do
        expect(create(:benin_bank_account).currency).to eq("xof")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:benin_bank_account, account_number_last_four: "0769").account_number_visual).to eq("BJ******0769")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:benin_bank_account).routing_number).to be nil
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:benin_bank_account)).to be_valid
        expect(build(:benin_bank_account, account_number: "BJ66AJ06101001001KR390000760")).to be_valid

        bj_bank_account = build(:benin_bank_account, account_number: "FR66BJ0610100100144390000769")
        expect(bj_bank_account).not_to be_valid
        expect(bj_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bj_bank_account = build(:benin_bank_account, account_number: "BJ66BJ061010010014439000076")
        expect(bj_bank_account).not_to be_valid
        expect(bj_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bj_bank_account = build(:benin_bank_account, account_number: "BJ66BJ06101001001443900007690")
        expect(bj_bank_account).not_to be_valid
        expect(bj_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bj_bank_account = build(:benin_bank_account, account_number: "9066890610100100144390000769")
        expect(bj_bank_account).not_to be_valid
        expect(bj_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
