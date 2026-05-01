# frozen_string_literal: true

class ElSalvadorBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "SV"

  BANK_CODE_FORMAT_REGEX = /^[a-zA-Z0-9]{8,11}$/
  PLAIN_ACCOUNT_NUMBER_REGEX = /\A[0-9]{10,20}\z/
  IBAN_FORMAT_REGEX = /\ASV[0-9]{2}[A-Z]{4}[0-9]{20}\z/
  private_constant :BANK_CODE_FORMAT_REGEX, :PLAIN_ACCOUNT_NUMBER_REGEX, :IBAN_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  validate :validate_account_number

  def routing_number
    bank_code
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::SLV.alpha2
  end

  def currency
    Currency::USD
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

  def stripe_account_number(passphrase)
    raw = account_number.decrypt(passphrase).gsub(/[ -]/, "")
    return raw if IBAN_FORMAT_REGEX.match?(raw)
    self.class.build_iban(bank_code, raw)
  end

  def self.build_iban(swift, account)
    bank_code = swift[0, 4].upcase
    bban = "#{bank_code}#{account.rjust(20, "0")}"
    rearranged = "#{bban}SV00"
    numeric = rearranged.upcase.chars.map { |c| c.match?(/[A-Z]/) ? (c.ord - 55).to_s : c }.join
    check_digits = (98 - (numeric.to_i % 97)).to_s.rjust(2, "0")
    "SV#{check_digits}#{bban}"
  end

  private
    def validate_bank_code
      return if BANK_CODE_FORMAT_REGEX.match?(bank_code)
      errors.add :base, "The bank code is invalid."
    end

    def validate_account_number
      decrypted = account_number_decrypted
      return if PLAIN_ACCOUNT_NUMBER_REGEX.match?(decrypted)
      return if IBAN_FORMAT_REGEX.match?(decrypted) && Ibandit::IBAN.new(decrypted).valid?
      errors.add :base, "The account number is invalid."
    end
end
