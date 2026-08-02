# frozen_string_literal: true

class IndonesiaBankAccount < BankAccount
  include StrippedFields

  BANK_ACCOUNT_TYPE = "ID"

  # Stripe's ID rail resolves the bank from its own Sandi Bank directory, which is exactly 3 digits.
  # Anything else (a SWIFT-ish `BBSB`, a zero-padded `0140`) saves here and then fails bank-sync with
  # routing_number_invalid, leaving the seller unpayable with no visible error.
  BANK_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{1,35}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  stripped_fields :account_holder_full_name, remove_duplicate_spaces: false, nilify_blanks: false

  validate :validate_bank_code, if: -> { will_save_change_to_bank_number? }
  validate :validate_account_number

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::IDN.alpha2
  end

  def currency
    Currency::IDR
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
      errors.add :base, "Enter your bank's 3-digit Indonesian bank code, digits only."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
