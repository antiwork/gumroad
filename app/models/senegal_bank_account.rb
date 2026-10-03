# frozen_string_literal: true

class SenegalBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "SN"

  # Senegal IBAN: SN + 2 check digits + 2-char bank code + 22 digits = 28 chars, fixed. Stripe also
  # checks the mod-97 digits, so a length-only match would still fail later at bank-sync.
  IBAN_FORMAT_REGEX = /\ASN[0-9]{2}[0-9A-Z]{2}[0-9]{22}\z/
  private_constant :IBAN_FORMAT_REGEX

  # Only on write: rows saved under the looser rule must not break unrelated saves like mark_deleted!.
  validate :validate_account_number, if: -> { will_save_change_to_account_number? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::SEN.alpha2
  end

  def currency
    Currency::XOF
  end

  def account_number_visual
    "******#{account_number_last_four}"
  end

  def to_hash
    {
      account_number: account_number_visual,
      bank_account_type:
    }
  end

  private
    def validate_account_number
      decrypted = account_number_decrypted
      # Match the raw value: Ibandit upcases and strips whitespace, which Stripe would not.
      return if decrypted.present? && IBAN_FORMAT_REGEX.match?(decrypted) && Ibandit::IBAN.new(decrypted).valid_check_digits?
      errors.add :base, "The account number is invalid. Enter your 28-character IBAN: SN followed by 26 characters."
    end
end
