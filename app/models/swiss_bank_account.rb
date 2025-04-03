# frozen_string_literal: true

class SwissBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "CH"

  ACCOUNT_NUMBER_FORMAT_REGEX = /\ACH[0-9]{7}[A-Za-z0-9]{12}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::CHE.alpha2
  end

  def currency
    Currency::CHF
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
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
