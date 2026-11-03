# frozen_string_literal: true

class IcelandBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "IS"

  validate :validate_account_number

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::ISL.alpha2
  end

  def currency
    Currency::EUR
  end

  def to_hash
    {
      account_number: account_number_visual,
      bank_account_type:
    }
  end
end
