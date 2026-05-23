# frozen_string_literal: true

require "test_helper"

class BruneiBankAccountTest < ActiveSupport::TestCase
  self.described_class = BruneiBankAccount


  context_ BruneiBankAccount do
  context_ "#bank_account_type" do
  test "returns BN" do
        expect(create(:brunei_bank_account).bank_account_type).to eq("BN")
      end
    end

  context_ "#country" do
  test "returns BN" do
        expect(create(:brunei_bank_account).country).to eq("BN")
      end
    end

  context_ "#currency" do
  test "returns bnd" do
        expect(create(:brunei_bank_account).currency).to eq("bnd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:brunei_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAABNBBXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:brunei_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:brunei_bank_account)).to be_valid
        expect(build(:brunei_bank_account, account_number: "000012345")).to be_valid
        expect(build(:brunei_bank_account, account_number: "1")).to be_valid
        expect(build(:brunei_bank_account, account_number: "000012345678")).to be_valid

        bn_bank_account = build(:brunei_bank_account, account_number: "000012345678910")
        expect(bn_bank_account).not_to be_valid
        expect(bn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bn_bank_account = build(:brunei_bank_account, account_number: "BN0012345678910")
        expect(bn_bank_account).not_to be_valid
        expect(bn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
