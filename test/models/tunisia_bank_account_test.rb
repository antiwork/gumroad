# frozen_string_literal: true

require "test_helper"

class TunisiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = TunisiaBankAccount


  context_ TunisiaBankAccount do
  context_ "#bank_account_type" do
  test "returns Tunisia" do
        expect(create(:tunisia_bank_account).bank_account_type).to eq("TN")
      end
    end

  context_ "#country" do
  test "returns TN" do
        expect(create(:tunisia_bank_account).country).to eq("TN")
      end
    end

  context_ "#currency" do
  test "returns tnd" do
        expect(create(:tunisia_bank_account).currency).to eq("tnd")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:tunisia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("TN******2345")
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:tunisia_bank_account)).to be_valid
        expect(build(:tunisia_bank_account, account_number: "TN 5904 0181 0400 4942 7123 45")).to be_valid

        tn_bank_account = build(:tunisia_bank_account, account_number: "TN12345")
        expect(tn_bank_account).not_to be_valid
        expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        tn_bank_account = build(:tunisia_bank_account, account_number: "DE61109010140000071219812874")
        expect(tn_bank_account).not_to be_valid
        expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        tn_bank_account = build(:tunisia_bank_account, account_number: "8937040044053201300000")
        expect(tn_bank_account).not_to be_valid
        expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        tn_bank_account = build(:tunisia_bank_account, account_number: "TNABCDE")
        expect(tn_bank_account).not_to be_valid
        expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
