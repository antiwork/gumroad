# frozen_string_literal: true

class SwedenBankAccount < BankAccount
  include IbanBankAccount

  BANK_ACCOUNT_TYPE = "SE"

  # Swedish IBAN: SE + 2 check digits + 3-digit clearing/bank code + 17-digit
  # account number = 24 chars. We validate the STRUCTURE + mod-97 check digits
  # ourselves instead of delegating to Ibandit's full `iban.valid?`, which also
  # asserts the clearing code exists in Ibandit's bundled SE bank registry. That
  # registry lags real banks: it false-rejects valid IBANs from newer institutions
  # our payout rail (Stripe) accepts fine — e.g. Lunar Bank's Swedish clearing range
  # `9710` (gumroad-private#775). Same class as the Côte d'Ivoire registry gap (#471).
  # We still use Ibandit's working country-code / check-digit / length / character
  # checks for the parts of the standard it validates correctly.
  IBAN_FORMAT_REGEX = /\ASE[0-9]{2}[0-9]{3}[0-9]{17}\z/
  private_constant :IBAN_FORMAT_REGEX

  validate :validate_account_number, if: -> { Rails.env.production? }

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::SWE.alpha2
  end

  def currency
    Currency::SEK
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
    # Sweden-scoped override of IbanBankAccount#validate_account_number — see the
    # IBAN_FORMAT_REGEX comment above. Validates SE structure + Ibandit's working
    # sub-checks, but NOT the bundled bank-code registry that false-rejects Lunar.
    def validate_account_number
      decrypted = account_number_decrypted
      if decrypted.blank?
        errors.add :base, "The account number is invalid."
        return
      end
      iban = Ibandit::IBAN.new(decrypted)
      return if IBAN_FORMAT_REGEX.match?(iban.iban) &&
                iban.valid_country_code? &&
                iban.valid_check_digits? &&
                iban.valid_length? &&
                iban.valid_characters?
      errors.add :base, "The account number is invalid."
    end
end
