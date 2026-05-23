# frozen_string_literal: true

require "test_helper"

class BahrainBankAccountTest < ActiveSupport::TestCase
  self.described_class = BahrainBankAccount


  context_ BahrainBankAccount do
  context_ "#bank_account_type" do
  test "returns BH" do
        expect(create(:bahrain_bank_account).bank_account_type).to eq("BH")
      end
    end

  context_ "#country" do
  test "returns BH" do
        expect(create(:bahrain_bank_account).country).to eq("BH")
      end
    end

  context_ "#currency" do
  test "returns bhd" do
        expect(create(:bahrain_bank_account).currency).to eq("bhd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:bahrain_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAABHBMXYZ")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:bahrain_bank_account, account_number_last_four: "BH00").account_number_visual).to eq("BH******BH00")
      end
    end
  end
end
