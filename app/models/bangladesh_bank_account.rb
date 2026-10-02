# frozen_string_literal: true

class BangladeshBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "BD"

  BANK_CODE_FORMAT_REGEX = /\A[0-9]{9}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /^([0-9a-zA-Z]){13,17}$/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
  validate :validate_account_number

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::BGD.alpha2
  end

  def currency
    Currency::BDT
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
      errors.add :base, "Enter your bank's 9-digit BEFTN routing number (for example 250110123), not a SWIFT/BIC code."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "Bangladesh account numbers are 13 to 17 digits. If yours is shorter, your bank's full-length format usually adds leading zeros (for example, 12345678901 becomes 0012345678901)."
    end
end
