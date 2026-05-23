# frozen_string_literal: true

require "test_helper"

class MongoliaBankAccountTest < ActiveSupport::TestCase
  self.described_class = MongoliaBankAccount



  context_ MongoliaBankAccount do
  context_ "#bank_account_type" do
  test "returns MN" do
        expect(create(:mongolia_bank_account).bank_account_type).to eq("MN")
      end
    end

  context_ "#country" do
  test "returns MN" do
        expect(create(:mongolia_bank_account).country).to eq("MN")
      end
    end

  context_ "#currency" do
  test "returns mnt" do
        expect(create(:mongolia_bank_account).currency).to eq("mnt")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:mongolia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAMNUBXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:mongolia_bank_account, account_number_last_four: "2001").account_number_visual).to eq("******2001")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:mongolia_bank_account, bank_code: "AAAAMNUBXXX")).to be_valid
        expect(build(:mongolia_bank_account, bank_code: "AAAAMNUB")).to be_valid
        expect(build(:mongolia_bank_account, bank_code: "AAAAMNUBXXXX")).not_to be_valid
        expect(build(:mongolia_bank_account, bank_code: "AAAAMNU")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
      let(:bank_account) { build(:mongolia_bank_account) }

  test "validates account number format" do
        bank_account.account_number = "000123456789"
        bank_account.account_number_last_four = "6789"
        expect(bank_account).to be_valid

        bank_account.account_number = "1234"
        bank_account.account_number_last_four = "1234"
        expect(bank_account).to be_valid

        bank_account.account_number = "1234567890123456"
        bank_account.account_number_last_four = "3456"
        expect(bank_account).not_to be_valid
      end
    end
  end
end
