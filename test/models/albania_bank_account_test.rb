# frozen_string_literal: true

require "test_helper"

class AlbaniaBankAccountTest < ActiveSupport::TestCase
  self.described_class = AlbaniaBankAccount


  context_ AlbaniaBankAccount do
  context_ "#bank_account_type" do
  test "returns AL" do
        expect(create(:albania_bank_account).bank_account_type).to eq("AL")
      end
    end

  context_ "#country" do
  test "returns AL" do
        expect(create(:albania_bank_account).country).to eq("AL")
      end
    end

  context_ "#currency" do
  test "returns all" do
        expect(create(:albania_bank_account).currency).to eq("all")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:albania_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAALTXXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:albania_bank_account, account_number_last_four: "4567").account_number_visual).to eq("AL******4567")
      end
    end
  end
end
