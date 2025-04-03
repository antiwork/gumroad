# frozen_string_literal: true

class ChileBankAccount < BankAccount
  include ChileBankAccount::AccountType
  BANK_ACCOUNT_TYPE = "CL"

  BANK_CODE_FORMAT_REGEX = /\A[0-9]{3}\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{5,25}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  before_validation :set_default_account_type, on: :create, if: ->(chile_bank_account) { chile_bank_account.account_type.nil? }

  validate :validate_bank_code
  validate :validate_account_number
  validates :account_type, inclusion: { in: AccountType.all }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::CHL.alpha2
  end

  def currency
    Currency::CLP
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
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end

    def set_default_account_type
      self.account_type = AccountType::CHECKING
    end
end
