# frozen_string_literal: true

class DominicanRepublicBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "DO"

  BANK_CODE_FORMAT_REGEX = /^\d{1,3}$/
  BRANCH_CODE_FORMAT_REGEX = /^\d{1,5}$/
  ACCOUNT_NUMBER_FORMAT_REGEX = /^\d{1,28}$/
  private_constant :BANK_CODE_FORMAT_REGEX, :BRANCH_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  # Branch code is optional (Stripe accepts the bare bank_code alone, per gp#2050's live test
  # results), but any value a seller DOES enter still gets concatenated into routing_number sent
  # to Stripe — so it needs the same format guard as bank_code, just without the presence check.
  validate :validate_branch_code
  validate :validate_account_number

  validates :bank_code, presence: true
  validates :account_number, presence: true

  def routing_number
    branch_code.present? ? "#{bank_code}-#{branch_code}" : "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::DOM.alpha2
  end

  def currency
    Currency::DOP
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
      # Presence is optional (nil/blank branch_code is a valid, Stripe-accepted account) — only
      # reject a PRESENT value that doesn't match, so blank keeps passing.
      return if branch_code.blank? || BRANCH_CODE_FORMAT_REGEX.match?(branch_code)
      errors.add :base, "The branch code is invalid."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
