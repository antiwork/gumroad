# frozen_string_literal: true

class MoroccoBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "MA"

  BANK_CODE_FORMAT_REGEX = /^([a-zA-Z]){4}([a-zA-Z]){2}([0-9a-zA-Z]){2}([0-9a-zA-Z]{3})?$/
  private_constant :BANK_CODE_FORMAT_REGEX

  # Morocco IBAN: MA + 2 check digits + 24 digits = 28 chars, fixed. Stripe rejects anything else,
  # including a 28-char value whose mod-97 check digits don't compute, so a length-only check would
  # still let a bad value save here and fail later at bank-sync. Ibandit's own `valid?` is unusable
  # for the same bundled-data reason Niger works around: the MA structure has no per-field format
  # regexes, and the nil formats compile to /\A\z/, rejecting every valid MA IBAN.
  IBAN_FORMAT_REGEX = /\AMA[0-9]{26}\z/
  private_constant :IBAN_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  # Only on write: 397 live rows predate the fixed-length rule, and re-validating them would raise on
  # unrelated saves — mark_deleted! when a seller switches to PayPal aborts the switch after their
  # Stripe account has already been deleted externally, which no rollback undoes.
  validate :validate_account_number, if: -> { Rails.env.production? && will_save_change_to_account_number? }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::MAR.alpha2
  end

  def currency
    Currency::MAD
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

    def validate_account_number
      decrypted = account_number_decrypted
      if decrypted.present?
        # Match the raw value, not `iban.iban`: Ibandit upcases and strips whitespace, so matching
        # its normalized form would accept a value we then store and send to Stripe as typed.
        iban = Ibandit::IBAN.new(decrypted)
        return if IBAN_FORMAT_REGEX.match?(decrypted) &&
                  iban.valid_country_code? &&
                  iban.valid_check_digits? &&
                  iban.valid_length? &&
                  iban.valid_characters?
      end
      errors.add :base, "The account number is invalid. Enter your 28-character IBAN: MA followed by 26 digits, not your RIB."
    end
end
