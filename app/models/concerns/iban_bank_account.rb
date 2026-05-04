# frozen_string_literal: true

module IbanBankAccount
  extend ActiveSupport::Concern

  SEPA_COUNTRY_CODES = %w[
    AT BE BG CH CY CZ DE DK EE ES FI FR GB GI GR HR
    HU IE IS IT LI LT LU LV MC MT NL NO PL PT RO SE
    SI SK SM
  ].freeze

  def stripe_external_account_country
    cross_border_sepa_payout? ? iban_country_code : country
  end

  def stripe_external_account_currency
    cross_border_sepa_payout? ? Currency::EUR : currency
  end

  def stripe_external_account_routing_number
    cross_border_sepa_payout? ? nil : routing_number
  end

  private
    def iban_country_code
      return if account_number_decrypted.blank?
      Ibandit::IBAN.new(account_number_decrypted).country_code
    end

    def cross_border_sepa_payout?
      iban = iban_country_code
      return false if iban.blank? || iban == country
      SEPA_COUNTRY_CODES.include?(iban)
    end

    def validate_account_number
      iban = Ibandit::IBAN.new(account_number_decrypted)
      unless iban.valid?
        errors.add(:base, "The account number is invalid.")
        return
      end
      return if SEPA_COUNTRY_CODES.include?(iban.country_code)
      errors.add(:base, "The account number is invalid.")
    end
end
