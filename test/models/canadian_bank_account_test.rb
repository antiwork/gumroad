# frozen_string_literal: true

require "test_helper"

class CanadianBankAccountTest < ActiveSupport::TestCase
  self.described_class = CanadianBankAccount



  context_ CanadianBankAccount do
  context_ "transit_number" do
  context_ "is 5 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "12345") }

  test "is valid" do
          expect(canadian_bank_account).to be_valid
        end
      end

  context_ "nil" do
        let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: nil) }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "is 4 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "is 6 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "123456") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "contains alpha characters" do
        let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234a") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end
    end

  context_ "institution_number" do
  context_ "is 3 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "123") }

  test "is valid" do
          expect(canadian_bank_account).to be_valid
        end
      end

  context_ "nil" do
        let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: nil) }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "is 2 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "is 4 digits" do
        let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "1234") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end

  context_ "contains alpha characters" do
        let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12a") }

  test "is not valid" do
          expect(canadian_bank_account).not_to be_valid
        end
      end
    end

  context_ "routing_number" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "45678", institution_number: "123") }

  test "is a concat of institution_number, hyphen and transit_number" do
        expect(canadian_bank_account.routing_number).to eq("45678-123")
      end
    end
  end
end
