# frozen_string_literal: true

class OmanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "OM"

  BANK_CODE_FORMAT_REGEX = /^[A-Z]{4}OM[A-Z0-9]{2,5}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /^[0-9]{6,16}$/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_account_number, if: -> { Rails.env.production? }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::OMN.alpha2
  end

  def currency
    Currency::OMR
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
      iban = Ibandit::IBAN.new(account_number_decrypted)
      return if iban.valid? && iban.country_code == "OM"
      errors.add :base, "The account number is invalid."
    end
end
