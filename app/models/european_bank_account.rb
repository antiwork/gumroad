# frozen_string_literal: true

class EuropeanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "EU"

  # On sandbox, the test IBAN numbers are of same length for all countries
  # (ref: https://stripe.com/docs/connect/testing#account-numbers),
  # so validating this only for production.
  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    ISO3166::Country[account_number_decrypted[0, 2]].alpha2
  end

  def currency
    Currency::EUR
  end

  def account_number_visual
    "#{country}******#{account_number_last_four}"
  end

  def to_hash
    {
      account_number: account_number_visual,
      bank_account_type:
    }
  end

  private
    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end
end
