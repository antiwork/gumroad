# frozen_string_literal: true

class PolandBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "PL"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::POL.alpha2
  end

  def currency
    Currency::PLN
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
end
