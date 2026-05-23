# frozen_string_literal: true

require "test_helper"

class AntiguaAndBarbudaBankAccountTest < ActiveSupport::TestCase
  self.described_class = AntiguaAndBarbudaBankAccount


  context_ AntiguaAndBarbudaBankAccount do
  context_ "#bank_account_type" do
  test "returns AG" do
        expect(create(:antigua_and_barbuda_bank_account).bank_account_type).to eq("AG")
      end
    end

  context_ "#country" do
  test "returns AG" do
        expect(create(:antigua_and_barbuda_bank_account).country).to eq("AG")
      end
    end

  context_ "#currency" do
  test "returns xcd" do
        expect(create(:antigua_and_barbuda_bank_account).currency).to eq("xcd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAGXYZ")).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAG")).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGAGXYZZ")).not_to be_valid
        expect(build(:antigua_and_barbuda_bank_account, bank_code: "AAAAAGA")).not_to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:antigua_and_barbuda_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:antigua_and_barbuda_bank_account)).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, account_number: "00012345678910111213141516171819")).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, account_number: "ABC12345678910111213141516171819")).to be_valid
        expect(build(:antigua_and_barbuda_bank_account, account_number: "12345678910111213141516171819ABC")).to be_valid

        ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "000123456789101112131415161718192")
        expect(ag_bank_account).not_to be_valid
        expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "ABCD12345678910111213141516171819")
        expect(ag_bank_account).not_to be_valid
        expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "12345678910111213141516171819ABCD")
        expect(ag_bank_account).not_to be_valid
        expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        ag_bank_account = build(:antigua_and_barbuda_bank_account, account_number: "AB12345678910111213141516171819CD")
        expect(ag_bank_account).not_to be_valid
        expect(ag_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
