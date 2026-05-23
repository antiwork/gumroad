# frozen_string_literal: true

require "test_helper"

class BahamasBankAccountTest < ActiveSupport::TestCase
  self.described_class = BahamasBankAccount



  context_ BahamasBankAccount do
  context_ "#bank_account_type" do
  test "returns BS" do
        expect(create(:bahamas_bank_account).bank_account_type).to eq("BS")
      end
    end

  context_ "#country" do
  test "returns BS" do
        expect(create(:bahamas_bank_account).country).to eq("BS")
      end
    end

  context_ "#currency" do
  test "returns bsd" do
        expect(create(:bahamas_bank_account).currency).to eq("bsd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:bahamas_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAABSNSXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:bahamas_bank_account, account_number_last_four: "1234").account_number_visual).to eq("******1234")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:bahamas_bank_account, bank_code: "AAAABSNS")).to be_valid
        expect(build(:bahamas_bank_account, bank_code: "AAAABSNSXXX")).to be_valid
        expect(build(:bahamas_bank_account, bank_code: "AAAABS")).not_to be_valid
        expect(build(:bahamas_bank_account, bank_code: "AAAABSNSXXXX")).not_to be_valid
      end
    end
  end
end
