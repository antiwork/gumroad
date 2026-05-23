# frozen_string_literal: true

require "test_helper"

class MauritiusBankAccountTest < ActiveSupport::TestCase
  self.described_class = MauritiusBankAccount


  context_ MauritiusBankAccount do
  context_ "#bank_account_type" do
  test "returns MU" do
        expect(create(:mauritius_bank_account).bank_account_type).to eq("MU")
      end
    end

  context_ "#country" do
  test "returns MA" do
        expect(create(:mauritius_bank_account).country).to eq("MU")
      end
    end

  context_ "#currency" do
  test "returns mad" do
        expect(create(:mauritius_bank_account).currency).to eq("mur")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:mauritius_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAMUMUXYZ")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:mauritius_bank_account, account_number_last_four: "9123").account_number_visual).to eq("MU******9123")
      end
    end
  end
end
