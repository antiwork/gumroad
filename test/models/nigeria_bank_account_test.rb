# frozen_string_literal: true

require "test_helper"

class NigeriaBankAccountTest < ActiveSupport::TestCase
  self.described_class = NigeriaBankAccount


  context_ NigeriaBankAccount do
  context_ "#bank_account_type" do
  test "returns NG" do
        expect(create(:nigeria_bank_account).bank_account_type).to eq("NG")
      end
    end

  context_ "#country" do
  test "returns NG" do
        expect(create(:nigeria_bank_account).country).to eq("NG")
      end
    end

  context_ "#currency" do
  test "returns ngn" do
        expect(create(:nigeria_bank_account).currency).to eq("ngn")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:nigeria_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAANGLAXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:nigeria_bank_account, account_number_last_four: "1112").account_number_visual).to eq("NG******1112")
      end
    end
  end
end
