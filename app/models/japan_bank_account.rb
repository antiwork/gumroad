# frozen_string_literal: true

class JapanBankAccount < BankAccount
  include StrippedFields

  BANK_ACCOUNT_TYPE = "JP"

  BANK_CODE_FORMAT_REGEX = /\A[0-9]{4}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  BRANCH_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BRANCH_CODE_FORMAT_REGEX

  # Stripe rejects Japanese account numbers shorter than 7 digits at tokenization
  # ("must be 7-8 digits"), so accepting 4-6 digits here only delays the failure to a
  # raw Stripe error after submit. Match Stripe's bounds so the seller gets inline
  # validation instead. Verified by live token probes, 2026-07-20 (gumroad-private#1180).
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{7,8}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  # Zengin-format account names allow katakana, digits, and the symbols ( ) . - /
  # (plus space). Japanese corporate accounts are registered with the entity-type
  # abbreviation and a parenthesis — e.g. カ)～ (株式会社), ド)～ (合同会社) — so the
  # symbol set is required, not optional. Full-width variants are normalized to the
  # half-width forms Zengin/Stripe expect (see stripped_fields transform below).
  ZENGIN_SYMBOLS_AND_DIGITS = "0-9().\\-\\/"
  private_constant :ZENGIN_SYMBOLS_AND_DIGITS

  KATAKANA_NAME_FORMAT_REGEX = /\A(?=.*[\p{Katakana}\uFF66-\uFF9F])[\p{Katakana}ー・\uFF65-\uFF9F\u3000#{ZENGIN_SYMBOLS_AND_DIGITS}]+\z/
  private_constant :KATAKANA_NAME_FORMAT_REGEX

  LATIN_NAME_FORMAT_REGEX = /\A(?=.*[A-Za-z])[A-Za-z #{ZENGIN_SYMBOLS_AND_DIGITS}]+\z/
  private_constant :LATIN_NAME_FORMAT_REGEX

  # Full-width digits/symbols → the half-width equivalents Zengin uses.
  FULL_WIDTH_TO_HALF_WIDTH = ["０-９（）．－／", "0-9().-/"].freeze
  private_constant :FULL_WIDTH_TO_HALF_WIDTH

  alias_attribute :bank_code, :bank_number

  stripped_fields :account_holder_full_name,
                  remove_duplicate_spaces: false,
                  nilify_blanks: false,
                  transform: ->(value) {
                    normalized = value.tr(*FULL_WIDTH_TO_HALF_WIDTH)
                    full_width = normalized.tr(" ", "　")
                    if KATAKANA_NAME_FORMAT_REGEX.match?(full_width)
                      full_width
                    elsif LATIN_NAME_FORMAT_REGEX.match?(normalized)
                      normalized
                    else
                      value
                    end
                  }

  validate :validate_bank_code
  validate :validate_branch_code
  validate :validate_account_number
  validate :validate_account_holder_full_name,
           if: -> { account_holder_full_name.present? },
           unless: :deleted?

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
      return if KATAKANA_NAME_FORMAT_REGEX.match?(account_holder_full_name) || LATIN_NAME_FORMAT_REGEX.match?(account_holder_full_name)
      errors.add :account_holder_full_name, "must be written in either katakana or Latin letters — not both."
    end
end
