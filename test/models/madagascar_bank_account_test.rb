# frozen_string_literal: true

require "test_helper"

class MadagascarBankAccountTest < ActiveSupport::TestCase
  self.described_class = MadagascarBankAccount


  context_ MadagascarBankAccount do
  context_ "#bank_account_type" do
  test "returns Madagascar" do
        expect(create(:madagascar_bank_account).bank_account_type).to eq("MG")
      end
    end

  context_ "#country" do
  test "returns MG" do
        expect(create(:madagascar_bank_account).country).to eq("MG")
      end
    end

  context_ "#currency" do
  test "returns mga" do
        expect(create(:madagascar_bank_account).currency).to eq("mga")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:madagascar_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAMGMGXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:madagascar_bank_account, account_number_last_four: "0123").account_number_visual).to eq("******0123")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:madagascar_bank_account)).to be_valid
        expect(build(:madagascar_bank_account, account_number: "MG4800005000011234567890123")).to be_valid

        mg_bank_account = build(:madagascar_bank_account, account_number: "MG12345")
        expect(mg_bank_account).not_to be_valid
        expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        mg_bank_account = build(:madagascar_bank_account, account_number: "DE61109010140000071219812874")
        expect(mg_bank_account).not_to be_valid
        expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        mg_bank_account = build(:madagascar_bank_account, account_number: "8937040044053201300000")
        expect(mg_bank_account).not_to be_valid
        expect(mg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end

  test "accepts an IBAN with spaces between groups" do
        expect(build(:madagascar_bank_account, account_number: "MG48 0000 5000 0112 3456 7890 123")).to be_valid
      end

  test "accepts an IBAN with dashes between groups" do
        expect(build(:madagascar_bank_account, account_number: "MG48-0000-5000-0112-3456-7890-123")).to be_valid
      end
    end
  end
end
