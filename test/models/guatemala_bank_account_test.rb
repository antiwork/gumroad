# frozen_string_literal: true

require "test_helper"

class GuatemalaBankAccountTest < ActiveSupport::TestCase
  self.described_class = GuatemalaBankAccount



  context_ GuatemalaBankAccount do
  context_ "#bank_account_type" do
  test "returns GT" do
        expect(create(:guatemala_bank_account).bank_account_type).to eq("GT")
      end
    end

  context_ "#country" do
  test "returns GT" do
        expect(create(:guatemala_bank_account).country).to eq("GT")
      end
    end

  context_ "#currency" do
  test "returns gtq" do
        expect(create(:guatemala_bank_account).currency).to eq("gtq")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:guatemala_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAGTGCXYZ")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:guatemala_bank_account, account_number_last_four: "7890").account_number_visual).to eq("******7890")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:guatemala_bank_account, bank_code: "AAAAGTGCXYZ")).to be_valid
        expect(build(:guatemala_bank_account, bank_code: "AAAAGTGC")).to be_valid
        expect(build(:guatemala_bank_account, bank_code: "AAAAGTG")).not_to be_valid
        expect(build(:guatemala_bank_account, bank_code: "AAAAGTGCXYZZ")).not_to be_valid
      end
    end
  end
end
