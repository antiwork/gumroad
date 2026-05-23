# frozen_string_literal: true

require "test_helper"

class BulgariaBankAccountTest < ActiveSupport::TestCase
  self.described_class = BulgariaBankAccount



  context_ BulgariaBankAccount do
  context_ "#bank_account_type" do
  test "returns bulgaria" do
        expect(create(:bulgaria_bank_account).bank_account_type).to eq("BG")
      end
    end

  context_ "#country" do
  test "returns BG" do
        expect(create(:bulgaria_bank_account).country).to eq("BG")
      end
    end

  context_ "#currency" do
  test "returns eur" do
        expect(create(:bulgaria_bank_account).currency).to eq("eur")
      end
    end

  context_ "#routing_number" do
  test "returns nil" do
        expect(create(:bulgaria_bank_account).routing_number).to be nil
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number with country code prefixed" do
        expect(create(:bulgaria_bank_account, account_number_last_four: "2874").account_number_visual).to eq("BG******2874")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:bulgaria_bank_account)).to be_valid
        expect(build(:bulgaria_bank_account, account_number: "BG80 BNBG 9661 1020 3456 78")).to be_valid

        bg_bank_account = build(:bulgaria_bank_account, account_number: "BG12345")
        expect(bg_bank_account).not_to be_valid
        expect(bg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bg_bank_account = build(:bulgaria_bank_account, account_number: "DE61109010140000071219812874")
        expect(bg_bank_account).not_to be_valid
        expect(bg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bg_bank_account = build(:bulgaria_bank_account, account_number: "8937040044053201300000")
        expect(bg_bank_account).not_to be_valid
        expect(bg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        bg_bank_account = build(:bulgaria_bank_account, account_number: "BGABCDE")
        expect(bg_bank_account).not_to be_valid
        expect(bg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
