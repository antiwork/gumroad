# frozen_string_literal: true

class AngolaBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "AO"

  BANK_CODE_FORMAT_REGEX = /^([0-9a-zA-Z]){8,11}$/
  private_constant :BANK_CODE_FORMAT_REGEX

  # Angola NIB (legacy): 21 numeric digits
  ACCOUNT_NUMBER_NIB_REGEX = /\A\d{21}\z/
  private_constant :ACCOUNT_NUMBER_NIB_REGEX

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
    Compliance::Countries::AGO.alpha2
  end

  def currency
    Currency::AOA
  end

  def account_number_visual
    "#{country}******#{account_number_last_four}"
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
      sanitized = account_number_decrypted.gsub(/\s/, "")
      return if ACCOUNT_NUMBER_NIB_REGEX.match?(sanitized)
      iban = Ibandit::IBAN.new(sanitized)
      return if iban.valid? && iban.country_code == "AO"
      errors.add :base, "The account number is invalid."
    end
end
