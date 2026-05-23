# frozen_string_literal: true

require "test_helper"

class ArmeniaBankAccountTest < ActiveSupport::TestCase
  self.described_class = ArmeniaBankAccount



  context_ ArmeniaBankAccount do
  context_ "#bank_account_type" do
  test "returns AM" do
        expect(create(:armenia_bank_account).bank_account_type).to eq("AM")
      end
    end

  context_ "#country" do
  test "returns AM" do
        expect(create(:armenia_bank_account).country).to eq("AM")
      end
    end

  context_ "#currency" do
  test "returns amd" do
        expect(create(:armenia_bank_account).currency).to eq("amd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        ba = create(:armenia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAAMNNXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:armenia_bank_account, account_number_last_four: "4567").account_number_visual).to eq("******4567")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:armenia_bank_account, bank_code: "AAAAAMNNXXX")).to be_valid
        expect(build(:armenia_bank_account, bank_code: "AAAAAMNN")).to be_valid
        expect(build(:armenia_bank_account, bank_code: "AAAAAMNNXXXX")).not_to be_valid
        expect(build(:armenia_bank_account, bank_code: "AAAAAMN")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows 11 to 16 digits only" do
        expect(build(:armenia_bank_account, account_number: "00001234567")).to be_valid
        expect(build(:armenia_bank_account, account_number: "0000123456789012")).to be_valid
        expect(build(:armenia_bank_account, account_number: "0000123456")).not_to be_valid
        expect(build(:armenia_bank_account, account_number: "00001234567890123")).not_to be_valid
      end
    end
  end
end
