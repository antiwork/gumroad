# frozen_string_literal: true

require "test_helper"

class TrinidadAndTobagoBankAccountTest < ActiveSupport::TestCase
  self.described_class = TrinidadAndTobagoBankAccount



  context_ TrinidadAndTobagoBankAccount do
  context_ "#bank_account_type" do
  test "returns TT" do
        expect(create(:trinidad_and_tobago_bank_account).bank_account_type).to eq("TT")
      end
    end

  context_ "#country" do
  test "returns TT" do
        expect(create(:trinidad_and_tobago_bank_account).country).to eq("TT")
      end
    end

  context_ "#currency" do
  test "returns ttd" do
        expect(create(:trinidad_and_tobago_bank_account).currency).to eq("ttd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 digits" do
        ba = create(:trinidad_and_tobago_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("99900001")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:trinidad_and_tobago_bank_account, account_number_last_four: "9999").account_number_visual).to eq("******9999")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 3 digits only" do
        expect(build(:trinidad_and_tobago_bank_account, bank_code: "110")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, bank_code: "123")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, bank_code: "11")).not_to be_valid
        expect(build(:trinidad_and_tobago_bank_account, bank_code: "ABC")).not_to be_valid
      end
    end

  context_ "#validate_branch_code" do
  test "allows 5 digits only" do
        expect(build(:trinidad_and_tobago_bank_account, branch_code: "11001")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, branch_code: "12345")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, branch_code: "110011")).not_to be_valid
        expect(build(:trinidad_and_tobago_bank_account, branch_code: "ABCDE")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:trinidad_and_tobago_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, account_number: "123456789")).to be_valid
        expect(build(:trinidad_and_tobago_bank_account, account_number: "123456789012345")).to be_valid

        tt_bank_account = build(:trinidad_and_tobago_bank_account, account_number: "ABCDEFGHIJKL")
        expect(tt_bank_account).not_to be_valid
        expect(tt_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        tt_bank_account = build(:trinidad_and_tobago_bank_account, account_number: "8937040044053201300000")
        expect(tt_bank_account).not_to be_valid
        expect(tt_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
