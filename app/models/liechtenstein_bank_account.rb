# frozen_string_literal: true

class LiechtensteinBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "LI"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::LIE.alpha2
  end

  def currency
    Currency::CHF
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
end
