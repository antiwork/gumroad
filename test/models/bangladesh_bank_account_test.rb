# frozen_string_literal: true

require "test_helper"

class BangladeshBankAccountTest < ActiveSupport::TestCase
  self.described_class = BangladeshBankAccount


  context_ BangladeshBankAccount do
  context_ "#bank_account_type" do
  test "returns BD" do
        expect(create(:bangladesh_bank_account).bank_account_type).to eq("BD")
      end
    end

  context_ "#country" do
  test "returns BD" do
        expect(create(:bangladesh_bank_account).country).to eq("BD")
      end
    end

  context_ "#currency" do
  test "returns bdt" do
        expect(create(:bangladesh_bank_account).currency).to eq("bdt")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 9 characters" do
        ba = create(:bangladesh_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("110000000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:bangladesh_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:bangladesh_bank_account)).to be_valid
        expect(build(:bangladesh_bank_account, account_number: "0000123456789")).to be_valid
        expect(build(:bangladesh_bank_account, account_number: "00001234567891011")).to be_valid

        bd_bank_account = build(:bangladesh_bank_account, account_number: "000012345678")
        expect(bd_bank_account).not_to be_valid
        expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bd_bank_account = build(:bangladesh_bank_account, account_number: "0000123456789101112")
        expect(bd_bank_account).not_to be_valid
        expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bd_bank_account = build(:bangladesh_bank_account, account_number: "BD00123456789101112")
        expect(bd_bank_account).not_to be_valid
        expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bd_bank_account = build(:bangladesh_bank_account, account_number: "BDABC")
        expect(bd_bank_account).not_to be_valid
        expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
