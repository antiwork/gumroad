# frozen_string_literal: true

class PakistanBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "PK"

  BANK_CODE_FORMAT_REGEX = /^([a-zA-Z]){4}([a-zA-Z]){2}([0-9a-zA-Z]){2}([0-9a-zA-Z]{3})?$/
  private_constant :BANK_CODE_FORMAT_REGEX

  # IBAN bank codes (characters 5-8) that Stripe's PK directory cannot route: mobile wallets and
  # microfinance banks. Stripe picks the bank from this segment, not from the BIC, so no BIC the
  # seller enters can make one of these attach.
  UNROUTABLE_IBAN_BANK_CODES = %w[CLRB FMFB FNJA JAZZ JCMA MMBL NAYA NRSP SADA TMFB TRWI UMBL UMFB ZTBL].freeze
  private_constant :UNROUTABLE_IBAN_BANK_CODES

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_account_number
  # Only on write: existing rows must stay deletable when the seller switches payout method.
  validate :validate_iban_bank_is_routable, if: -> { new_record? || will_save_change_to_account_number? }

  def routing_number
    "#{bank_code}"
  end

  def stripe_external_account_routing_number
    # Stripe resolves only an uppercase PK BIC — it rejects a lowercase one on format, before any
    # directory lookup — so the seller's own casing must not reach it.
    # Stripe links PK head-office BICs, but rejects branch-specific suffixes.
    code = routing_number.upcase
    code.end_with?("XXX") ? code : code.first(8)
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::PAK.alpha2
  end

  def currency
    Currency::PKR
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

    def validate_account_number
      return if Ibandit::IBAN.new(account_number_decrypted).valid?

      errors.add :base, "The account number is invalid."
    end

    def validate_iban_bank_is_routable
      iban = Ibandit::IBAN.new(account_number_decrypted)
      return unless iban.country_code == "PK" && UNROUTABLE_IBAN_BANK_CODES.include?(iban.bank_code)

      errors.add :base, "We can't send payouts to this IBAN. Wallet and microfinance accounts such as SadaPay, NayaPay, " \
                        "JazzCash and Easypaisa aren't supported. Enter the IBAN of an account at a commercial bank."
    end
end
