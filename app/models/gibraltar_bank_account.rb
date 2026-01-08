# frozen_string_literal: true

class GibraltarBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "GI"

  SORT_CODE_FORMAT_REGEX = /^\d{2}-\d{2}-\d{2}$/
  ACCOUNT_NUMBER_FORMAT_REGEX = /^\d{8}$/
  private_constant :SORT_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :sort_code, :bank_number

  validate :validate_sort_code
  validate :validate_account_number

  def routing_number
    sort_code
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::GIB.alpha2
  end

  def currency
    Currency::GBP
  end

  def account_number_visual
    "******#{account_number_last_four}"
  end

  private
    def validate_sort_code
      return if SORT_CODE_FORMAT_REGEX.match?(sort_code)
      errors.add :base, "The sort code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
