# frozen_string_literal: true

class NewZealandBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "NZ"

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{15,16}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  validate :validate_account_number

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::NZL.alpha2
  end

  def currency
    Currency::NZD
  end

  def account_number_visual
    "******#{account_number_last_four}"
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
