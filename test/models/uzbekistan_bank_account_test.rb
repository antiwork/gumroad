# frozen_string_literal: true

require "test_helper"

class UzbekistanBankAccountTest < ActiveSupport::TestCase
  self.described_class = UzbekistanBankAccount



  context_ UzbekistanBankAccount do
  context_ "#bank_account_type" do
  test "returns UZ" do
        expect(create(:uzbekistan_bank_account).bank_account_type).to eq("UZ")
      end
    end

  context_ "#country" do
  test "returns UZ" do
        expect(create(:uzbekistan_bank_account).country).to eq("UZ")
      end
    end

  context_ "#currency" do
  test "returns uzs" do
        expect(create(:uzbekistan_bank_account).currency).to eq("uzs")
      end
    end

  context_ "#routing_number" do
  test "returns valid bank code and branch code" do
        ba = create(:uzbekistan_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAUZUZXXX-00000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:uzbekistan_bank_account, account_number_last_four: "0024").account_number_visual).to eq("******0024")
      end
    end

  context_ "#validate_bank_code" do
  test "allows valid bank code format" do
        expect(build(:uzbekistan_bank_account, bank_code: "AAAAUZUZXXX")).to be_valid
        expect(build(:uzbekistan_bank_account, bank_code: "BBBBUZUZYYY")).to be_valid
        expect(build(:uzbekistan_bank_account, bank_code: "AAAAUZU")).not_to be_valid
        expect(build(:uzbekistan_bank_account, bank_code: "AAAAUZUZXXXX")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows valid account number format" do
        expect(build(:uzbekistan_bank_account, account_number: "99934500012345670024")).to be_valid
        expect(build(:uzbekistan_bank_account, account_number: "12345")).to be_valid
        expect(build(:uzbekistan_bank_account, account_number: "12345678901234567890")).to be_valid
        expect(build(:uzbekistan_bank_account, account_number: "1234")).not_to be_valid
        expect(build(:uzbekistan_bank_account, account_number: "123456789012345678901")).not_to be_valid
      end
    end
  end
end
