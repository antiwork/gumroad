# frozen_string_literal: true

require "test_helper"

class UkBankAccountTest < ActiveSupport::TestCase
  self.described_class = UkBankAccount



  context_ UkBankAccount do
  context_ "sort_code" do
  context_ "is 6 digits with hyphens" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: "06-21-11") }

  test "is valid" do
          expect(uk_bank_account).to be_valid
        end
      end

  context_ "nil" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: nil) }

  test "is not valid" do
          expect(uk_bank_account).not_to be_valid
        end
      end

  context_ "is 6 digits without hyphens" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: "123456") }

  test "is not valid" do
          expect(uk_bank_account).not_to be_valid
        end
      end

  context_ "is 5 digits" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12345") }

  test "is not valid" do
          expect(uk_bank_account).not_to be_valid
        end
      end

  context_ "is 7 digits with hyphens" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12-34-56-7") }

  test "is not valid" do
          expect(uk_bank_account).not_to be_valid
        end
      end

  context_ "contains alpha characters with hyphens" do
        let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12-34-5a") }

  test "is not valid" do
          expect(uk_bank_account).not_to be_valid
        end
      end
    end

  context_ "routing_number" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "45-37-80") }

  test "is the sort_code" do
        expect(uk_bank_account.routing_number).to eq("45-37-80")
      end
    end
  end
end
