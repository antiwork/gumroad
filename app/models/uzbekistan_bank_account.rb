# frozen_string_literal: true

class UzbekistanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "UZ"

  BANK_CODE_FORMAT_REGEX = /^([a-zA-Z0-9]){8,11}$/
  BRANCH_CODE_FORMAT_REGEX = /^([0-9]){5}$/
  ACCOUNT_NUMBER_FORMAT_REGEX = /^\d{5,20}$/
  private_constant :BANK_CODE_FORMAT_REGEX, :BRANCH_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_branch_code
  validate :validate_account_number

  def routing_number
    "#{bank_code}-#{branch_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::UZB.alpha2
  end

  def currency
    Currency::UZS
  end

  def account_number_visual
    "******#{account_number_last_four}"
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
