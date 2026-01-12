# frozen_string_literal: true

class UkBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "UK"

  SORT_CODE_FORMAT_REGEX = /^\d{2}-\d{2}-\d{2}$/
  private_constant :SORT_CODE_FORMAT_REGEX


  alias_attribute :sort_code, :bank_number

  validate :validate_sort_code

  def routing_number
    sort_code
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::GBR.alpha2
  end

  def currency
    Currency::GBP
  end

  private
    def validate_sort_code
      errors.add :base, "The sort code is invalid." unless SORT_CODE_FORMAT_REGEX.match?(sort_code)
    end
end
