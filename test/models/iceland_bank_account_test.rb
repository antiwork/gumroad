# frozen_string_literal: true

require "test_helper"

class IcelandBankAccountTest < ActiveSupport::TestCase
  self.described_class = IcelandBankAccount



  context_ IcelandBankAccount do
  context_ "#bank_account_type" do
  test "returns IS" do
        expect(create(:iceland_bank_account).bank_account_type).to eq("IS")
      end
    end

  context_ "#country" do
  test "returns IS" do
        expect(create(:iceland_bank_account).country).to eq("IS")
      end
    end

  context_ "#currency" do
  test "returns eur" do
        expect(create(:iceland_bank_account).currency).to eq("eur")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:iceland_bank_account, account_number_last_four: "0339").account_number_visual).to eq("IS******0339")
      end
    end

  context_ "#validate_account_number" do
  test "validates the IBAN format" do
        expect(build(:iceland_bank_account)).to be_valid
        expect(build(:iceland_bank_account, account_number: "IS1401592600765455107303")).not_to be_valid
        expect(build(:iceland_bank_account, account_number: "IS14015926007654551073033911")).not_to be_valid
      end
    end
  end
end
