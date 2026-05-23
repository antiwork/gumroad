# frozen_string_literal: true

require "test_helper"

class NigerBankAccountTest < ActiveSupport::TestCase
  self.described_class = NigerBankAccount


  context_ NigerBankAccount do
  context_ "#bank_account_type" do
  test "returns NE" do
        expect(create(:niger_bank_account).bank_account_type).to eq("NE")
      end
    end

  context_ "#country" do
  test "returns NE" do
        expect(create(:niger_bank_account).country).to eq("NE")
      end
    end

  context_ "#currency" do
  test "returns xof" do
        expect(create(:niger_bank_account).currency).to eq("xof")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:niger_bank_account, account_number_last_four: "0268").account_number_visual).to eq("NE******0268")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:niger_bank_account).routing_number).to be nil
      end
    end
  end
end
