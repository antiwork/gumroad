# frozen_string_literal: true

class HongKongBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "HK"

  CLEARING_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :CLEARING_CODE_FORMAT_REGEX

  BRANCH_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BRANCH_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{6,12}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :clearing_code, :bank_number

  validate :validate_clearing_code
  validate :validate_branch_code
  validate :validate_account_number

  def routing_number
    "#{clearing_code}-#{branch_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::HKG.alpha2
  end

  def currency
    Currency::HKD
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
    def validate_clearing_code
      return if CLEARING_CODE_FORMAT_REGEX.match?(clearing_code)
      errors.add :base, "The clearing code is invalid."
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
