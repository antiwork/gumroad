# frozen_string_literal: true

class AzerbaijanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "AZ"

  BANK_CODE_FORMAT_REGEX = /^\d{6}$/
  private_constant :BANK_CODE_FORMAT_REGEX

  BRANCH_CODE_FORMAT_REGEX = /^\d{6}$/
  private_constant :BRANCH_CODE_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_branch_code
  validate :validate_account_number, if: -> { Rails.env.production? }

  def routing_number
    "#{bank_code}-#{branch_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::AZE.alpha2
  end

  def currency
    Currency::AZN
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

    def validate_branch_code
      return if BRANCH_CODE_FORMAT_REGEX.match?(branch_code)
      errors.add :base, "The branch code is invalid."
    end

    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end
end
