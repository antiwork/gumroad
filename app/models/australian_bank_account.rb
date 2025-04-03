# frozen_string_literal: true

class AustralianBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "AUSTRALIAN"

  # BSB Number Format:
  #  • 2 digits to identify bank
  #  • 1 digit to identify state
  #  • 3 digits to identify branch
  BSB_NUMBER_FORMAT_REGEX = /^[0-9]{6}$/
  private_constant :BSB_NUMBER_FORMAT_REGEX

  alias_attribute :bsb_number, :bank_number

  validate :validate_bsb_number

  def routing_number
    bsb_number
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::AUS.alpha2
  end

  def currency
    Currency::AUD
  end

  def to_hash
    super.merge(
      bsb_number:
    )
  end

  private
    def validate_bsb_number
      errors.add :base, "The BSB number is invalid." unless BSB_NUMBER_FORMAT_REGEX.match?(bsb_number)
    end
end
