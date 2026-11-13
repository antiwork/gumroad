# frozen_string_literal: true

class EthiopiaBankAccount < BankAccount
  include BicCountryValidation

  BANK_ACCOUNT_TYPE = "ET"

  # Stripe's ET rail resolves only the 8-character BIC or its 11-character branch-suffixed form, so
  # a 9- or 10-character code saves here and then never attaches.
  BANK_CODE_FORMAT_REGEX = /\A[0-9a-zA-Z]{8}([0-9a-zA-Z]{3})?\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  # Stripe's ET rail takes digits only (13-16). An alphanumeric account number saves here and then
  # fails bank-sync with account_number_invalid, leaving the seller unpayable with no visible error.
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{13,16}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  # Only on write: rows stored while the old range admitted 9- and 10-character codes must stay
  # savable and deletable — mark_deleted! validates when a seller switches payout method.
  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
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
      return errors.add(:base, "The bank code is invalid.") unless BANK_CODE_FORMAT_REGEX.match?(bank_code)

      validate_bank_code_country(BANK_ACCOUNT_TYPE)
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
