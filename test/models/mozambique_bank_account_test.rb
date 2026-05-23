# frozen_string_literal: true

require "test_helper"

class MozambiqueBankAccountTest < ActiveSupport::TestCase
  self.described_class = MozambiqueBankAccount


  context_ MozambiqueBankAccount do
  context_ "#bank_account_type" do
  test "returns MZ" do
        expect(create(:mozambique_bank_account).bank_account_type).to eq("MZ")
      end
    end

  context_ "#country" do
  test "returns MZ" do
        expect(create(:mozambique_bank_account).country).to eq("MZ")
      end
    end

  context_ "#currency" do
  test "returns mzn" do
        expect(create(:mozambique_bank_account).currency).to eq("mzn")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:mozambique_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAMZMXXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:mozambique_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:mozambique_bank_account)).to be_valid
        expect(build(:mozambique_bank_account, account_number: "001234567890123456789")).to be_valid
        expect(build(:mozambique_bank_account, account_number: "00123456789012345678")).not_to be_valid
        expect(build(:mozambique_bank_account, account_number: "0012345678901234567890")).not_to be_valid
      end
    end
  end
end
