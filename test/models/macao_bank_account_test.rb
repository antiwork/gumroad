# frozen_string_literal: true

require "test_helper"

class MacaoBankAccountTest < ActiveSupport::TestCase
  self.described_class = MacaoBankAccount


  context_ MacaoBankAccount do
  context_ "#bank_account_type" do
  test "returns MO" do
        expect(create(:macao_bank_account).bank_account_type).to eq("MO")
      end
    end

  context_ "#country" do
  test "returns MO" do
        expect(create(:macao_bank_account).country).to eq("MO")
      end
    end

  context_ "#currency" do
  test "returns MOP" do
        expect(create(:macao_bank_account).currency).to eq("mop")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:macao_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAMOMXXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:macao_bank_account, account_number_last_four: "7897").account_number_visual).to eq("******7897")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:macao_bank_account)).to be_valid
        expect(build(:macao_bank_account, account_number: "0000000001234567897")).to be_valid
        expect(build(:macao_bank_account, account_number: "0")).to be_valid
        expect(build(:macao_bank_account, account_number: "0000123456789101")).to be_valid

        mo_bank_account = build(:macao_bank_account, account_number: "00001234567891234567890")
        expect(mo_bank_account).not_to be_valid
        expect(mo_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end

  context_ "#validate_bank_code" do
  test "validates bank code format" do
        expect(build(:macao_bank_account, bank_code: "AAAAMOMXXXX")).to be_valid
        expect(build(:macao_bank_account, bank_code: "BBBBMOMBXXX")).to be_valid

        mo_bank_account = build(:macao_bank_account, bank_code: "INVALIDCODEE")
        expect(mo_bank_account).not_to be_valid
        expect(mo_bank_account.errors.full_messages.to_sentence).to eq("The bank code is invalid.")
      end
    end
  end
end
