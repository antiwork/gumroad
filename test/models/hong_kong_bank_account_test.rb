# frozen_string_literal: true

require "test_helper"

class HongKongBankAccountTest < ActiveSupport::TestCase
  self.described_class = HongKongBankAccount



  context_ HongKongBankAccount do
  context_ "#bank_account_type" do
  test "returns hong kong" do
        expect(create(:hong_kong_bank_account).bank_account_type).to eq("HK")
      end
    end

  context_ "#country" do
  test "returns HK" do
        expect(create(:hong_kong_bank_account).country).to eq("HK")
      end
    end

  context_ "#currency" do
  test "returns hkd" do
        expect(create(:hong_kong_bank_account).currency).to eq("hkd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 6 digits with hyphen after 3" do
        ba = create(:hong_kong_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("110-000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:hong_kong_bank_account, account_number_last_four: "3456").account_number_visual).to eq("******3456")
      end
    end

  context_ "#validate_clearing_code" do
  test "allows 3 digits only" do
        expect(build(:hong_kong_bank_account, clearing_code: "110")).to be_valid
        expect(build(:hong_kong_bank_account, clearing_code: "123")).to be_valid
        expect(build(:hong_kong_bank_account, clearing_code: "1100")).not_to be_valid
        expect(build(:hong_kong_bank_account, clearing_code: "ABC")).not_to be_valid
      end
    end

  context_ "#validate_branch_code" do
  test "allows 3 digits only" do
        expect(build(:hong_kong_bank_account, branch_code: "110")).to be_valid
        expect(build(:hong_kong_bank_account, branch_code: "123")).to be_valid
        expect(build(:hong_kong_bank_account, branch_code: "1100")).not_to be_valid
        expect(build(:hong_kong_bank_account, branch_code: "ABC")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:hong_kong_bank_account, account_number: "000123456")).to be_valid
        expect(build(:hong_kong_bank_account, account_number: "123456789")).to be_valid
        expect(build(:hong_kong_bank_account, account_number: "012345678910")).to be_valid

        hk_bank_account = build(:hong_kong_bank_account, account_number: "ABCDEFGHI")
        expect(hk_bank_account).not_to be_valid
        expect(hk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        hk_bank_account = build(:hong_kong_bank_account, account_number: "8937040044053201300000")
        expect(hk_bank_account).not_to be_valid
        expect(hk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        hk_bank_account = build(:hong_kong_bank_account, account_number: "CHABCDE")
        expect(hk_bank_account).not_to be_valid
        expect(hk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
