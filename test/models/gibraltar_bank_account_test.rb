# frozen_string_literal: true

require "test_helper"

class GibraltarBankAccountTest < ActiveSupport::TestCase
  self.described_class = GibraltarBankAccount



  context_ GibraltarBankAccount do
  context_ "#bank_account_type" do
  test "returns gibraltar" do
        expect(create(:gibraltar_bank_account).bank_account_type).to eq("GI")
      end
    end

  context_ "#country" do
  test "returns GI" do
        expect(create(:gibraltar_bank_account).country).to eq("GI")
      end
    end

  context_ "#currency" do
  test "returns gbp" do
        expect(create(:gibraltar_bank_account).currency).to eq("gbp")
      end
    end

  context_ "#routing_number" do
  test "returns the sort code" do
        expect(create(:gibraltar_bank_account, sort_code: "12-34-56").routing_number).to eq("12-34-56")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:gibraltar_bank_account, account_number_last_four: "4567").account_number_visual).to eq("******4567")
      end
    end

  context_ "#validate_sort_code" do
  test "allows records that match the required sort code format" do
        expect(build(:gibraltar_bank_account, sort_code: "12-34-56")).to be_valid
        expect(build(:gibraltar_bank_account, sort_code: "00-00-00")).to be_valid
        expect(build(:gibraltar_bank_account, sort_code: "99-99-99")).to be_valid
      end

  test "rejects records with invalid sort code format" do
        gi_bank_account = build(:gibraltar_bank_account, sort_code: "123456")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The sort code is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, sort_code: "12-34-5")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The sort code is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, sort_code: "AB-CD-EF")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The sort code is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, sort_code: "")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The sort code is invalid.")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required 8-digit account number format" do
        expect(build(:gibraltar_bank_account, account_number: "01234567")).to be_valid
        expect(build(:gibraltar_bank_account, account_number: "00000000")).to be_valid
        expect(build(:gibraltar_bank_account, account_number: "99999999")).to be_valid
      end

  test "rejects records with invalid account number format" do
        gi_bank_account = build(:gibraltar_bank_account, account_number: "1234567")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, account_number: "123456789")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, account_number: "ABCDEFGH")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        gi_bank_account = build(:gibraltar_bank_account, account_number: "GI75NWBK000000007099453")
        expect(gi_bank_account).not_to be_valid
        expect(gi_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
