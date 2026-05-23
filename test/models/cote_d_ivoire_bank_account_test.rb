# frozen_string_literal: true

require "test_helper"

class CoteDIvoireBankAccountTest < ActiveSupport::TestCase
  self.described_class = CoteDIvoireBankAccount


  context_ CoteDIvoireBankAccount do
  context_ "#bank_account_type" do
  test "returns CI" do
        expect(create(:cote_d_ivoire_bank_account).bank_account_type).to eq("CI")
      end
    end

  context_ "#country" do
  test "returns CI" do
        expect(create(:cote_d_ivoire_bank_account).country).to eq("CI")
      end
    end

  context_ "#currency" do
  test "returns xof" do
        expect(create(:cote_d_ivoire_bank_account).currency).to eq("xof")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:cote_d_ivoire_bank_account, account_number_last_four: "0589").account_number_visual).to eq("CI******0589")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:cote_d_ivoire_bank_account).routing_number).to be nil
      end
    end
  end
end
