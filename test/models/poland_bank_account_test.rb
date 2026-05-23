# frozen_string_literal: true

require "test_helper"

class PolandBankAccountTest < ActiveSupport::TestCase
  self.described_class = PolandBankAccount



  context_ PolandBankAccount do
  context_ "#bank_account_type" do
  test "returns poland" do
        expect(create(:poland_bank_account).bank_account_type).to eq("PL")
      end
    end

  context_ "#country" do
  test "returns PL" do
        expect(create(:poland_bank_account).country).to eq("PL")
      end
    end

  context_ "#currency" do
  test "returns pln" do
        expect(create(:poland_bank_account).currency).to eq("pln")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:poland_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:poland_bank_account, account_number_last_four: "2874").account_number_visual).to eq("PL******2874")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:poland_bank_account)).to be_valid
        expect(build(:poland_bank_account, account_number: "PL61 1090 1014 0000 0712 1981 2874")).to be_valid

        pl_bank_account = build(:poland_bank_account, account_number: "PL12345")
        expect(pl_bank_account).not_to be_valid
        expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pl_bank_account = build(:poland_bank_account, account_number: "DE61109010140000071219812874")
        expect(pl_bank_account).not_to be_valid
        expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pl_bank_account = build(:poland_bank_account, account_number: "8937040044053201300000")
        expect(pl_bank_account).not_to be_valid
        expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pl_bank_account = build(:poland_bank_account, account_number: "PLABCDE")
        expect(pl_bank_account).not_to be_valid
        expect(pl_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
