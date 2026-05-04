# frozen_string_literal: true

class DenmarkBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "DK"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::DNK.alpha2
  end

  def currency
    Currency::DKK
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
