# frozen_string_literal: true

class DominicanRepublicBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "DO"

  BANK_CODE_FORMAT_REGEX = /^\d{1,3}$/
  BRANCH_CODE_FORMAT_REGEX = /^\d{1,5}$/
  ACCOUNT_NUMBER_FORMAT_REGEX = /^\d{1,28}$/
  # Stripe requires the concatenated bank + branch code to be exactly 8 digits (format xxxxxxxx);
  # the individual bank/branch regexes above are looser, so this catches valid-looking segments
  # that combine to the wrong length.
  ROUTING_NUMBER_FORMAT_REGEX = /\A\d{8}\z/
  private_constant :BANK_CODE_FORMAT_REGEX, :BRANCH_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX,
                   :ROUTING_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  # Only on write: branch_code was optional before this fix, so an existing row saved without one
  # would otherwise fail validation on any unrelated future save (e.g. switching payout method).
  validate :validate_branch_code, if: -> { new_record? || will_save_change_to_branch_code? }
  # routing_number combines bank_code and branch_code, so a bank-code-only edit (bank_code is
  # aliased to bank_number) must re-check it too, not just branch_code changes.
  validate :validate_routing_number, if: -> { new_record? || will_save_change_to_branch_code? || will_save_change_to_bank_number? }
  validate :validate_account_number

  validates :bank_code, presence: true
  validates :branch_code, presence: true, if: -> { new_record? || will_save_change_to_branch_code? }
  validates :account_number, presence: true

  # Stripe rejects a routing number without both segments concatenated with no separator
  # (routing_number_invalid: "must contain both the bank code and the branch code ... format
  # xxxxxxxx"), so branch_code can't stay optional and the dash has to go.
  def routing_number
    "#{bank_code}#{branch_code}"
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
      return if BRANCH_CODE_FORMAT_REGEX.match?(branch_code)
      errors.add :base, "The branch code is invalid."
    end

    def validate_routing_number
      return if ROUTING_NUMBER_FORMAT_REGEX.match?(routing_number)
      errors.add :base, "The bank code and branch code together must be 8 digits."
    end

    def validate_account_number
      return if ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted)
      errors.add :base, "The account number is invalid."
    end
end
