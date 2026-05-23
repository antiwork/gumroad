# frozen_string_literal: true

require "test_helper"

class PanamaBankAccountTest < ActiveSupport::TestCase
  self.described_class = PanamaBankAccount



  context_ PanamaBankAccount do
  context_ "#bank_account_type" do
  test "returns PA" do
        expect(create(:panama_bank_account).bank_account_type).to eq("PA")
      end
    end

  context_ "#country" do
  test "returns PA" do
        expect(create(:panama_bank_account).country).to eq("PA")
      end
    end

  context_ "#currency" do
  test "returns usd" do
        expect(create(:panama_bank_account).currency).to eq("usd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:panama_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAPAPAXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:panama_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 11 characters only" do
        expect(build(:panama_bank_account, bank_number: "AAAAPAPAXXX")).to be_valid
        expect(build(:panama_bank_account, bank_number: "AAAAPAPAXX")).not_to be_valid
        expect(build(:panama_bank_account, bank_number: "AAAAPAPAXXXX")).not_to be_valid
      end
    end
  end
end
