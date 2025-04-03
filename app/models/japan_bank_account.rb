# frozen_string_literal: true

class JapanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "JP"

  BANK_CODE_FORMAT_REGEX = /\A[0-9]{4}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  BRANCH_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BRANCH_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{4,8}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_branch_code
  validate :validate_account_number

  def routing_number
    "#{bank_code}#{branch_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::JPN.alpha2
  end

  def currency
    Currency::JPY
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

    def validate_branch_code
      return if BRANCH_CODE_FORMAT_REGEX.match?(branch_code)
      errors.add :base, "The branch code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
