# frozen_string_literal: true

class BeninBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "BJ"

  ACCOUNT_NUMBER_FORMAT_REGEX = /^BJ[a-zA-Z0-9]{26}$/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  validate :validate_account_number

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::BEN.alpha2
  end

  def currency
    Currency::XOF
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
