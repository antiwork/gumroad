# frozen_string_literal: true

class EgyptBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "EG"

  # Stripe's EG directory resolves the 8-char BIC and the XXX-padded 11-char form, but not an 11-char
  # value whose suffix is the bank's local branch number — the shape Egyptian banks print as "SWIFT +
  # branch". Those rows save here with no external account attached and never get paid.
  BANK_CODE_FORMAT_REGEX = /^[a-zA-Z]{6}[0-9a-zA-Z]{2}(?:XXX)?$/i
  private_constant :BANK_CODE_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  # Only on write: thousands of live rows predate this rule, and re-validating them would abort
  # unrelated saves — including the mark_deleted! a payout-method switch performs after the Stripe
  # account is already gone.
  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
  validate :validate_account_number

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::EGY.alpha2
  end

  def currency
    Currency::EGP
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
      errors.add :base, "Enter your bank's 8-character SWIFT/BIC code (for example NBEGEGCX); the branch number is not part of it."
    end

    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end
end
