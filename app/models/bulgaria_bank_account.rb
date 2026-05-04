# frozen_string_literal: true

class BulgariaBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "BG"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::BGR.alpha2
  end

  def currency
    Currency::EUR
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
