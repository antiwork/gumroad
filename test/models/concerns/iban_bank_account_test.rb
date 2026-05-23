# frozen_string_literal: true

require "test_helper"

class IbanBankAccountTest < ActiveSupport::TestCase
  self.described_class = IbanBankAccount



  context_ IbanBankAccount do
  context_ "#stripe_external_account_country" do
  test "returns the IBAN's country prefix when it differs from the account country and is in SEPA" do
        bank_account = build(:bulgaria_bank_account, account_number: "LT121000011101001000")
        expect(bank_account.stripe_external_account_country).to eq("LT")
      end

  test "returns the account's home country when the IBAN matches it" do
        bank_account = build(:bulgaria_bank_account, account_number: "BG80BNBG96611020345678")
        expect(bank_account.stripe_external_account_country).to eq("BG")
      end

  test "returns the account's home country when the IBAN prefix is non-SEPA" do
        bank_account = build(:bulgaria_bank_account, account_number: "SA0380000000608010167519")
        expect(bank_account.stripe_external_account_country).to eq("BG")
      end

  test "handles non-EUR home currency accounts (Denmark with Lithuanian IBAN)" do
        bank_account = build(:denmark_bank_account, account_number: "LT121000011101001000")
        expect(bank_account.stripe_external_account_country).to eq("LT")
      end
    end

  context_ "#stripe_external_account_currency" do
  test "returns 'eur' when the IBAN is cross-border within SEPA" do
        bank_account = build(:denmark_bank_account, account_number: "LT121000011101001000")
        expect(bank_account.stripe_external_account_currency).to eq("eur")
      end

  test "returns the account's home currency when the IBAN matches the home country" do
        bank_account = build(:denmark_bank_account, account_number: "DK5000400440116243")
        expect(bank_account.stripe_external_account_currency).to eq("dkk")
      end

  test "returns the account's home currency when the IBAN prefix is non-SEPA" do
        bank_account = build(:denmark_bank_account, account_number: "SA0380000000608010167519")
        expect(bank_account.stripe_external_account_currency).to eq("dkk")
      end
    end

  context_ "#stripe_external_account_routing_number" do
  test "returns nil when the IBAN is cross-border within SEPA, so a home-country BIC is not paired with a foreign IBAN" do
        bank_account = build(:san_marino_bank_account, account_number: "IT60X0542811101000000123456")
        expect(bank_account.stripe_external_account_routing_number).to be_nil
      end

  test "returns the account's routing_number when the IBAN matches the home country" do
        bank_account = build(:san_marino_bank_account, account_number: "SM86U0322509800000000270100")
        expect(bank_account.stripe_external_account_routing_number).to eq("AAAASMSMXXX")
      end

  test "returns nil for SEPA models that have no routing_number, regardless of cross-border status" do
        expect(build(:bulgaria_bank_account, account_number: "LT121000011101001000").stripe_external_account_routing_number).to be_nil
        expect(build(:bulgaria_bank_account, account_number: "BG80BNBG96611020345678").stripe_external_account_routing_number).to be_nil
      end
    end

  context_ "#validate_account_number" do
      before { allow(Rails.env).to receive(:production?).and_return(true) }

  test "accepts an IBAN whose country matches the account's home country" do
        expect(build(:bulgaria_bank_account, account_number: "BG80BNBG96611020345678")).to be_valid
      end

  test "accepts a cross-border IBAN within the SEPA zone" do
        expect(build(:bulgaria_bank_account, account_number: "LT121000011101001000")).to be_valid
        expect(build(:denmark_bank_account, account_number: "LT121000011101001000")).to be_valid
      end

  test "rejects an IBAN from a country outside the SEPA zone" do
        bank_account = build(:bulgaria_bank_account, account_number: "SA0380000000608010167519")
        expect(bank_account).not_to be_valid
        expect(bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end

  test "rejects IBANs from countries Stripe does not support (AD, VA)" do
        ad_account = build(:bulgaria_bank_account, account_number: "AD1400080001001234567890")
        expect(ad_account).not_to be_valid
        expect(ad_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        va_account = build(:bulgaria_bank_account, account_number: "VA59001123000012345678")
        expect(va_account).not_to be_valid
        expect(va_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end

  test "rejects an IBAN with an invalid format" do
        bank_account = build(:bulgaria_bank_account, account_number: "BG12345")
        expect(bank_account).not_to be_valid
        expect(bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end

  test "rejects a non-SEPA IBAN on EuropeanBankAccount, whose country derives from the IBAN prefix" do
        bank_account = build(:european_bank_account, account_number: "SA0380000000608010167519")
        expect(bank_account).not_to be_valid
        expect(bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
