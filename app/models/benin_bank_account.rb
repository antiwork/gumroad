# frozen_string_literal: true

class BeninBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "BJ"

  ACCOUNT_NUMBER_FORMAT_REGEX = /^BJ[a-zA-Z0-9]{26}$/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  # Only on write: rows saved under the looser rule must not break unrelated saves like mark_deleted!.
  validate :validate_account_number, if: -> { will_save_change_to_account_number? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::BEN.alpha2
  end

  def currency
    Currency::XOF
  end

  def account_number_visual
    "#{country}******#{account_number_last_four}"
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
      # Stripe also enforces the IBAN mod-97 check digits, so a 28-char value with wrong ones fails at bank-sync.
      return if decrypted.present? && ACCOUNT_NUMBER_FORMAT_REGEX.match?(decrypted) && Ibandit::IBAN.new(decrypted).valid_check_digits?
      errors.add :base, "The account number is invalid. Enter your 28-character IBAN starting with BJ and check the two digits after BJ."
    end
end
