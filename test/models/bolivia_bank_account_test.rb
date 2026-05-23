# frozen_string_literal: true

require "test_helper"

class BoliviaBankAccountTest < ActiveSupport::TestCase
  self.described_class = BoliviaBankAccount



  context_ BoliviaBankAccount do
  context_ "#bank_account_type" do
  test "returns BO" do
        expect(create(:bolivia_bank_account).bank_account_type).to eq("BO")
      end
    end

  context_ "#country" do
  test "returns BO" do
        expect(create(:bolivia_bank_account).country).to eq("BO")
      end
    end

  context_ "#currency" do
  test "returns bob" do
        expect(create(:bolivia_bank_account).currency).to eq("bob")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 3 digits" do
        ba = create(:bolivia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("040")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:bolivia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 1 to 3 digits only" do
        expect(build(:bolivia_bank_account, bank_code: "1")).to be_valid
        expect(build(:bolivia_bank_account, bank_code: "12")).to be_valid
        expect(build(:bolivia_bank_account, bank_code: "123")).to be_valid
        expect(build(:bolivia_bank_account, bank_code: "1234")).not_to be_valid
        expect(build(:bolivia_bank_account, bank_code: "a12")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows 10 to 15 digits only" do
        expect(build(:bolivia_bank_account, account_number: "1234567890")).to be_valid
        expect(build(:bolivia_bank_account, account_number: "123456789012345")).to be_valid
        expect(build(:bolivia_bank_account, account_number: "123456789")).not_to be_valid
        expect(build(:bolivia_bank_account, account_number: "1234567890123456")).not_to be_valid
        expect(build(:bolivia_bank_account, account_number: "12345a7890")).not_to be_valid
      end
    end
  end
end
