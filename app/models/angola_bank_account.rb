# frozen_string_literal: true

class AngolaBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "AO"

  BANK_CODE_FORMAT_REGEX = /^([0-9a-zA-Z]){8,11}$/
  private_constant :BANK_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\AAO[0-9]{23}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  before_validation :normalize_account_number
  validate :validate_bank_code
  validate :validate_account_number

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
    def normalize_account_number
      decrypted = account_number_decrypted.to_s
      return if decrypted.empty?
      cleaned = decrypted.strip.gsub(/[ -]/, "")
      return if cleaned == decrypted
      self.account_number = cleaned
      self.account_number_last_four = cleaned.last(4)
    end

    def validate_bank_code
      return if BANK_CODE_FORMAT_REGEX.match?(bank_code)
      errors.add :base, "The bank code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted.to_s)
      errors.add :base, "The account number is invalid."
    end
end
