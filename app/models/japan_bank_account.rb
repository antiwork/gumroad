# frozen_string_literal: true

class JapanBankAccount < BankAccount
  include StrippedFields

  BANK_ACCOUNT_TYPE = "JP"

  BANK_CODE_FORMAT_REGEX = /\A[0-9]{4}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  BRANCH_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BRANCH_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{4,8}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  # Stripe JP validates `account_holder_name` as a single-script value: all katakana or all Latin.
  # Katakana variant covers: full-width block (`\p{Katakana}`), the script-Common marks U+30FC (ー)
  # and U+30FB (・) that `\p{Katakana}` misses, half-width katakana (U+FF65-U+FF9F including voiced
  # and semi-voiced marks still common on JP input systems), and the full-width space U+3000.
  # ASCII space is deliberately only allowed in the Latin variant — mixing it with katakana is the
  # exact pattern Stripe rejects and the originating incident exposed.
  KATAKANA_NAME_FORMAT_REGEX = /\A[\p{Katakana}ー・\uFF65-\uFF9F\u3000]+\z/
  private_constant :KATAKANA_NAME_FORMAT_REGEX

  LATIN_NAME_FORMAT_REGEX = /\A[A-Za-z ]+\z/
  private_constant :LATIN_NAME_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  stripped_fields :account_holder_full_name, remove_duplicate_spaces: false, nilify_blanks: false

  validate :validate_bank_code
  validate :validate_branch_code
  validate :validate_account_number
  validate :validate_account_holder_full_name

  def routing_number
    "#{bank_code}#{branch_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::JPN.alpha2
  end

  def currency
    Currency::JPY
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
      errors.add :base, "The bank code is invalid."
    end

    def validate_branch_code
      return if BRANCH_CODE_FORMAT_REGEX.match?(branch_code)
      errors.add :base, "The branch code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end

    def validate_account_holder_full_name
      name = account_holder_full_name.to_s
      return if KATAKANA_NAME_FORMAT_REGEX.match?(name) || LATIN_NAME_FORMAT_REGEX.match?(name)
      errors.add(:account_holder_full_name,
                 "must be all katakana (use a full-width space between names) or all Latin letters. Mixing scripts is not allowed.")
    end
end
