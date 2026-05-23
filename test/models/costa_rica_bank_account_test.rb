# frozen_string_literal: true

require "test_helper"

class CostaRicaBankAccountTest < ActiveSupport::TestCase
  self.described_class = CostaRicaBankAccount


  context_ CostaRicaBankAccount do
  context_ "#bank_account_type" do
  test "returns Costa Rica" do
        expect(create(:costa_rica_bank_account).bank_account_type).to eq("CR")
      end
    end

  context_ "#country" do
  test "returns CR" do
        expect(create(:costa_rica_bank_account).country).to eq("CR")
      end
    end

  context_ "#currency" do
  test "returns crc" do
        expect(create(:costa_rica_bank_account).currency).to eq("crc")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:costa_rica_bank_account, account_number_last_four: "9123").account_number_visual).to eq("CR******9123")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:costa_rica_bank_account)).to be_valid
        expect(build(:costa_rica_bank_account, account_number: "CR 0401 0212 3678 5670 9123")).to be_valid

        cr_bank_account = build(:costa_rica_bank_account, account_number: "CR12345")
        expect(cr_bank_account).not_to be_valid
        expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cr_bank_account = build(:costa_rica_bank_account, account_number: "DE61109010140000071219812874")
        expect(cr_bank_account).not_to be_valid
        expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cr_bank_account = build(:costa_rica_bank_account, account_number: "8937040044053201300000")
        expect(cr_bank_account).not_to be_valid
        expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        cr_bank_account = build(:costa_rica_bank_account, account_number: "CRABCDE")
        expect(cr_bank_account).not_to be_valid
        expect(cr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
