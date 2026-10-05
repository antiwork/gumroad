# frozen_string_literal: true

class EthiopiaBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "ET"

  BANK_CODE_FORMAT_REGEX = /^[0-9a-zA-Z]{8,11}$/
  private_constant :BANK_CODE_FORMAT_REGEX

  # Stripe's ET rail takes digits only (13-16). An alphanumeric account number saves here and then
  # fails bank-sync with account_number_invalid, leaving the seller unpayable with no visible error.
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{13,16}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  # Only on write: 2,008 live rows predate the digits-only rule, and re-validating them would abort
  # unrelated saves — including the mark_deleted! a payout-method switch performs after the Stripe
  # account is already gone.
  validate :validate_account_number, if: -> { new_record? || will_save_change_to_account_number? }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::ETH.alpha2
  end

  def currency
    Currency::ETB
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
      errors.add :base, "The account number is invalid."
    end
end
