# frozen_string_literal: true

require "test_helper"

class AngolaBankAccountTest < ActiveSupport::TestCase
  self.described_class = AngolaBankAccount



  context_ AngolaBankAccount do
  context_ "#bank_account_type" do
  test "returns AO" do
        expect(create(:angola_bank_account).bank_account_type).to eq("AO")
      end
    end

  context_ "#country" do
  test "returns AO" do
        expect(create(:angola_bank_account).country).to eq("AO")
      end
    end

  context_ "#currency" do
  test "returns aoa" do
        expect(create(:angola_bank_account).currency).to eq("aoa")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:angola_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAAOAOXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:angola_bank_account, account_number_last_four: "0102").account_number_visual).to eq("AO******0102")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXX")).to be_valid
        expect(build(:angola_bank_account, bank_code: "AAAAAOAO")).to be_valid
        expect(build(:angola_bank_account, bank_code: "AAAAAOA")).not_to be_valid
        expect(build(:angola_bank_account, bank_code: "AAAAAOAOXXXX")).not_to be_valid
      end
    end
  end
end
