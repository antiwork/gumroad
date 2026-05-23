# frozen_string_literal: true

require "test_helper"

class JordanBankAccountTest < ActiveSupport::TestCase
  self.described_class = JordanBankAccount


  context_ JordanBankAccount do
  context_ "#bank_account_type" do
  test "returns JO" do
        expect(create(:jordan_bank_account).bank_account_type).to eq("JO")
      end
    end

  context_ "#country" do
  test "returns JO" do
        expect(create(:jordan_bank_account).country).to eq("JO")
      end
    end

  context_ "#currency" do
  test "returns jod" do
        expect(create(:jordan_bank_account).currency).to eq("jod")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:jordan_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAJOJOXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:jordan_bank_account, account_number_last_four: "5678").account_number_visual).to eq("JO******5678")
      end
    end
  end
end
