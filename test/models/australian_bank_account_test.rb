# frozen_string_literal: true

require "test_helper"

class AustralianBankAccountTest < ActiveSupport::TestCase
  self.described_class = AustralianBankAccount



  context_ AustralianBankAccount do
  context_ "bsb_number" do
  context_ "is 6 digits" do
        let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "062111") }

  test "is valid" do
          expect(australian_bank_account).to be_valid
        end
      end

  context_ "nil" do
        let(:australian_bank_account) { build(:australian_bank_account, bsb_number: nil) }

  test "is not valid" do
          expect(australian_bank_account).not_to be_valid
        end
      end

  context_ "is 5 digits" do
        let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "12345") }

  test "is not valid" do
          expect(australian_bank_account).not_to be_valid
        end
      end

  context_ "is 7 digits" do
        let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "1234567") }

  test "is not valid" do
          expect(australian_bank_account).not_to be_valid
        end
      end

  context_ "contains alpha characters" do
        let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "12345a") }

  test "is not valid" do
          expect(australian_bank_account).not_to be_valid
        end
      end
    end

  context_ "routing_number" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "453780") }

  test "is a concat of institution_number, hyphen and bsb_number" do
        expect(australian_bank_account.routing_number).to eq("453780")
      end
    end
  end
end
