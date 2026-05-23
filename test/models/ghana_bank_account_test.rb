# frozen_string_literal: true

require "test_helper"

class GhanaBankAccountTest < ActiveSupport::TestCase
  self.described_class = GhanaBankAccount


  context_ GhanaBankAccount do
  context_ "#bank_account_type" do
  test "returns GH" do
        expect(create(:ghana_bank_account).bank_account_type).to eq("GH")
      end
    end

  context_ "#country" do
  test "returns GH" do
        expect(create(:ghana_bank_account).country).to eq("GH")
      end
    end

  context_ "#currency" do
  test "returns ghs" do
        expect(create(:ghana_bank_account).currency).to eq("ghs")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 6 digits" do
        expect(create(:ghana_bank_account, bank_code: "022112")).to be_valid
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:ghana_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:ghana_bank_account)).to be_valid
        expect(build(:ghana_bank_account, account_number: "00012345678")).to be_valid
        expect(build(:ghana_bank_account, account_number: "000123456789")).to be_valid
        expect(build(:ghana_bank_account, account_number: "00012345678912345678")).to be_valid

        gh_bank_account = build(:ghana_bank_account, account_number: "1234567")
        expect(gh_bank_account).not_to be_valid
        expect(gh_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        gh_bank_account = build(:ghana_bank_account, account_number: "000123456789123456789")
        expect(gh_bank_account).not_to be_valid
        expect(gh_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        gh_bank_account = build(:ghana_bank_account, account_number: "ABCD12345678")
        expect(gh_bank_account).not_to be_valid
        expect(gh_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
