# frozen_string_literal: true

class DominicanRepublicBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "DO"

  # Exactly 3 digits, not 1-3: gp#2050's Stripe test only confirmed 3-digit codes (003/007/021)
  # as valid routing numbers. #7171 loosened this to 1-3 digits as a side effect of its own
  # (unrelated, since-reverted) branch_code work; restoring the exact-3 constraint Nyoman set in
  # 1301ff656 rather than reintroducing that unverified laxity.
  BANK_CODE_FORMAT_REGEX = /\A\d{3}\z/
  BRANCH_CODE_FORMAT_REGEX = /\A\d{1,5}\z/
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A\d{1,28}\z/
  private_constant :BANK_CODE_FORMAT_REGEX, :BRANCH_CODE_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  validate :validate_bank_code
  # Branch code is optional (Stripe accepts the bare bank_code alone, per gp#2050's live test
  # results), but any value a seller DOES enter still needs a format guard even though it isn't
  # sent to Stripe (see #routing_number) — an unvalidated column value is still a stored trust
  # boundary, and a future caller of branch_code shouldn't inherit garbage input silently.
  validate :validate_branch_code
  validate :validate_account_number

  validates :bank_code, presence: true
  validates :account_number, presence: true

  # Only bank_code is Stripe-verified: gp#2050 confirmed 3-digit codes (003/007/021) succeed and
  # 8-digit bank+branch concatenations fail with routing_number_invalid. Nothing has tested a
  # dash-joined bank_code-branch_code value, and the concatenated format is the one Stripe's own
  # error message says it wants instead — so branch_code, while still collected, is NEVER fed into
  # the value sent to Stripe until a branch-code-present case is actually verified against Stripe.
  def routing_number
    bank_code
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
