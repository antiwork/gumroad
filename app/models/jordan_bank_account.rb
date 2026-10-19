# frozen_string_literal: true

class JordanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "JO"

  # Stripe's JO directory resolves the 8-character BIC or its XXX-padded form, not a branch-number suffix.
  BANK_CODE_FORMAT_REGEX = /\A[A-Z]{4}JO[A-Z0-9]{2}(?:XXX)?\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  # Only on write: live rows predate this rule, and re-validating them would abort unrelated saves —
  # including the mark_deleted! a payout-method switch performs after the Stripe account is gone.
  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
  validate :validate_account_number, if: -> { Rails.env.production? }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::JOR.alpha2
  end

  def currency
    Currency::JOD
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
      errors.add :base, "Enter your bank's SWIFT/BIC code in capitals: 8 characters (for example IIBAJOAM), without the branch number."
    end

    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end
end
