# frozen_string_literal: true

class UruguayBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "UY"

  BANK_CODE_FORMAT_REGEX = /^\d{3}$/
  # BROU (Banco República, Uruguay's largest bank) issues 14-digit account
  # numbers (9-digit customer account + 5-digit sub-account). Stripe accepts
  # these account numbers, so allow up to 14 digits.
  ACCOUNT_NUMBER_FORMAT_REGEX = /^\d{1,14}$/
  private_constant :BANK_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_account_number

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::URY.alpha2
  end

  def currency
    Currency::UYU
  end

  def account_number_visual
    "******#{account_number_last_four}"
  end

  def to_hash
    {
      routing_number:,
      account_number: account_number_visual,
      bank_account_type:
    }
  end

  private
    def validate_bank_code
      return if BANK_CODE_FORMAT_REGEX.match?(bank_code)
      errors.add :base, "The bank code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
