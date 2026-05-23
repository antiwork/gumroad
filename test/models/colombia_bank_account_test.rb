# frozen_string_literal: true

require "test_helper"

class ColombiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = ColombiaBankAccount



  context_ ColombiaBankAccount do
  context_ "#bank_account_type" do
  test "returns Colombia" do
        expect(create(:colombia_bank_account).bank_account_type).to eq("CO")
      end
    end

  context_ "#country" do
  test "returns CO" do
        expect(create(:colombia_bank_account).country).to eq("CO")
      end
    end

  context_ "#currency" do
  test "returns cop" do
        expect(create(:colombia_bank_account).currency).to eq("cop")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 3 digits" do
        ba = create(:colombia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("060")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:colombia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 3 digits only" do
        expect(build(:colombia_bank_account, bank_code: "060")).to be_valid
        expect(build(:colombia_bank_account, bank_code: "111")).to be_valid
        expect(build(:colombia_bank_account, bank_code: "ABC")).not_to be_valid
        expect(build(:colombia_bank_account, bank_code: "0600")).not_to be_valid
        expect(build(:colombia_bank_account, bank_code: "06")).not_to be_valid
      end
    end

  context_ "account types" do
  test "allows checking account types" do
        colombia_bank_account = build(:colombia_bank_account, account_type: ColombiaBankAccount::AccountType::CHECKING)
        expect(colombia_bank_account).to be_valid
        expect(colombia_bank_account.account_type).to eq(ColombiaBankAccount::AccountType::CHECKING)
      end

  test "allows savings account types" do
        colombia_bank_account = build(:colombia_bank_account, account_type: ColombiaBankAccount::AccountType::SAVINGS)
        expect(colombia_bank_account).to be_valid
        expect(colombia_bank_account.account_type).to eq(ColombiaBankAccount::AccountType::SAVINGS)
      end

  test "invalidates other account types" do
        colombia_bank_account = build(:colombia_bank_account, account_type: "evil_account_type")
        expect(colombia_bank_account).not_to be_valid
      end

  test "translates a nil account type to the default (checking)" do
        colombia_bank_account = build(:colombia_bank_account, account_type: nil)
        expect(colombia_bank_account).to be_valid
        expect(colombia_bank_account.account_type).to eq(ColombiaBankAccount::AccountType::CHECKING)
      end
    end
  end
end
