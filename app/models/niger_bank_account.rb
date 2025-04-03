# frozen_string_literal: true

class NigerBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "NE"

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::NER.alpha2
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
      return if Ibandit::IBAN.new(account_number_decrypted).valid?
      errors.add :base, "The account number is invalid."
    end
end
