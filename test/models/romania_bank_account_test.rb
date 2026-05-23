# frozen_string_literal: true

require "test_helper"

class RomaniaBankAccountTest < ActiveSupport::TestCase
  self.described_class = RomaniaBankAccount



  context_ RomaniaBankAccount do
  context_ "#bank_account_type" do
  test "returns romania" do
        expect(create(:romania_bank_account).bank_account_type).to eq("RO")
      end
    end

  context_ "#country" do
  test "returns RO" do
        expect(create(:romania_bank_account).country).to eq("RO")
      end
    end

  context_ "#currency" do
  test "returns ron" do
        expect(create(:romania_bank_account).currency).to eq("ron")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:romania_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:romania_bank_account, account_number_last_four: "0000").account_number_visual).to eq("RO******0000")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:romania_bank_account)).to be_valid
        expect(build(:romania_bank_account, account_number: "RO49 AAAA 1B31 0075 9384 0000")).to be_valid

        ro_bank_account = build(:romania_bank_account, account_number: "RO12345")
        expect(ro_bank_account).not_to be_valid
        expect(ro_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ro_bank_account = build(:romania_bank_account, account_number: "DE61109010140000071219812874")
        expect(ro_bank_account).not_to be_valid
        expect(ro_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ro_bank_account = build(:romania_bank_account, account_number: "8937040044053201300000")
        expect(ro_bank_account).not_to be_valid
        expect(ro_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ro_bank_account = build(:romania_bank_account, account_number: "ROABCDE")
        expect(ro_bank_account).not_to be_valid
        expect(ro_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
