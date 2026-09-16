# frozen_string_literal: true

class EgyptBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "EG"

  # Stripe rejects a lowercase EG routing number outright ("Invalid routing number"), but whether an
  # 11-char branch code resolves is a per-BIC question only its own directory answers (NBEGEGCX331
  # does, QNBAEGCX027 does not), so the case is all this can enforce.
  BANK_CODE_FORMAT_REGEX = /^[A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?$/
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
      errors.add :base, "Enter your bank's SWIFT/BIC code in capitals: 8 characters, or 11 including the branch code (for example NBEGEGCX)."
    end

    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end
end
