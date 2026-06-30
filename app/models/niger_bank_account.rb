# frozen_string_literal: true

class NigerBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "NE"

  # Niger IBAN: NE + 2 check digits + 5-char bank code + 19-digit account number = 28 chars
  # (same XOF/BCEAO structure as Côte d'Ivoire). Note a Niger IBAN contains "NE" twice — once
  # as the country code and once inside the bank code.
  #
  # We validate the structure ourselves instead of delegating to Ibandit's per-field
  # `*_format` regexes: in Ibandit 1.26.1 the NE structure has `bank_code_format` and
  # `account_number_format` set to `nil`, which compile to `/\A\z/` (matches only the empty
  # string), so every structurally-valid NE IBAN is rejected as "format is invalid". We still
  # use Ibandit's working country-code / check-digit / length / character checks for the parts
  # of the standard it validates correctly. Same fix as Côte d'Ivoire (#471) and Sweden (#775).
  IBAN_FORMAT_REGEX = /\ANE[0-9]{2}[A-Z0-9]{5}[0-9]{19}\z/
  private_constant :IBAN_FORMAT_REGEX

  validate :validate_account_number

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::NER.alpha2
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
