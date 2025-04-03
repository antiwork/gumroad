# frozen_string_literal: true

class IndianBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "IN"

  # IFSC Format:
  #  • 4 chars to identify bank
  #  • 1 reserved digit, always 0
  #  • 6 chars to identify branch
  IFSC_FORMAT_REGEX = /^[A-Za-z]{4}0[A-Z0-9a-z]{6}$/
  private_constant :IFSC_FORMAT_REGEX

  alias_attribute :ifsc, :bank_number

  validate :validate_ifsc

  def routing_number
    ifsc
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::IND.alpha2
  end

  def currency
    Currency::INR
  end

  def to_hash
    {
      routing_number:,
      account_number: account_number_visual,
      bank_account_type:
    }
  end

  private
    def validate_ifsc
      errors.add :base, "The IFSC is invalid." unless IFSC_FORMAT_REGEX.match?(ifsc)
    end
end
