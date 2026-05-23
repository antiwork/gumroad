# frozen_string_literal: true

require "test_helper"

class ChileBankAccountTest < ActiveSupport::TestCase
  self.described_class = ChileBankAccount


  context_ ChileBankAccount do
  context_ "#bank_account_type" do
  test "returns Chile" do
        expect(create(:chile_bank_account).bank_account_type).to eq("CL")
      end
    end

  context_ "#country" do
  test "returns CL" do
        expect(create(:chile_bank_account).country).to eq("CL")
      end
    end

  context_ "#currency" do
  test "returns clp" do
        expect(create(:chile_bank_account).currency).to eq("clp")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 3 characters" do
        ba = create(:chile_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("999")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:chile_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 3 numeric characters only" do
        expect(build(:chile_bank_account, bank_code: "123")).to be_valid
        expect(build(:chile_bank_account, bank_code: "12")).not_to be_valid
        expect(build(:chile_bank_account, bank_code: "1234")).not_to be_valid
        expect(build(:chile_bank_account, bank_code: "12A")).not_to be_valid
        expect(build(:chile_bank_account, bank_code: "12@")).not_to be_valid
      end
    end

  context_ "account types" do
  test "allows checking account types" do
        chile_bank_account = build(:chile_bank_account, account_type: ChileBankAccount::AccountType::CHECKING)
        expect(chile_bank_account).to be_valid
        expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::CHECKING)
      end

  test "allows savings account types" do
        chile_bank_account = build(:chile_bank_account, account_type: ChileBankAccount::AccountType::SAVINGS)
        expect(chile_bank_account).to be_valid
        expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::SAVINGS)
      end

  test "invalidates other account types" do
        chile_bank_account = build(:chile_bank_account, account_type: "evil_account_type")
        expect(chile_bank_account).not_to be_valid
      end

  test "translates a nil account type to the default (checking)" do
        chile_bank_account = build(:chile_bank_account, account_type: nil)
        expect(chile_bank_account).to be_valid
        expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::CHECKING)
      end
    end
  end
end
