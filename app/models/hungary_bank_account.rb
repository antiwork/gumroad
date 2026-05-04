# frozen_string_literal: true

class HungaryBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "HU"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::HUN.alpha2
  end

  def currency
    Currency::HUF
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
