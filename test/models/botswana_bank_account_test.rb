# frozen_string_literal: true

require "test_helper"

class BotswanaBankAccountTest < ActiveSupport::TestCase
  self.described_class = BotswanaBankAccount


  context_ BotswanaBankAccount do
  context_ "#bank_account_type" do
  test "returns BW" do
        expect(create(:botswana_bank_account).bank_account_type).to eq("BW")
      end
    end

  context_ "#country" do
  test "returns BW" do
        expect(create(:botswana_bank_account).country).to eq("BW")
      end
    end

  context_ "#currency" do
  test "returns bwp" do
        expect(create(:botswana_bank_account).currency).to eq("bwp")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 8 to 11 characters" do
        expect(build(:botswana_bank_account, bank_code: "AAAAOMO")).not_to be_valid
        expect(build(:botswana_bank_account, bank_code: "AAAAOMOM")).to be_valid
        expect(build(:botswana_bank_account, bank_code: "AAAAOMOMX")).to be_valid
        expect(build(:botswana_bank_account, bank_code: "AAAAOMOMXX")).to be_valid
        expect(build(:botswana_bank_account, bank_code: "AAAAOMOMXXX")).to be_valid
        expect(build(:botswana_bank_account, bank_code: "AAAAOMOMXXXX")).not_to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:botswana_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:botswana_bank_account)).to be_valid
        expect(build(:botswana_bank_account, account_number: "123456")).to be_valid
        expect(build(:botswana_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:botswana_bank_account, account_number: "1234567890123456")).to be_valid
        expect(build(:botswana_bank_account, account_number: "ABCDEFGHIJKLMNOP")).to be_valid
      end

  test "rejects records that do not match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        botswana_bank_account = build(:botswana_bank_account, account_number: "00012345678910111")
        expect(botswana_bank_account).not_to be_valid
        expect(botswana_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        botswana_bank_account = build(:botswana_bank_account, account_number: "ABCDEFGHIJKLMNOPQ")
        expect(botswana_bank_account).not_to be_valid
        expect(botswana_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        botswana_bank_account = build(:botswana_bank_account, account_number: "BW123456789012345")
        expect(botswana_bank_account).not_to be_valid
        expect(botswana_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
