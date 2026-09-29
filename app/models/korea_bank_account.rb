# frozen_string_literal: true

class KoreaBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "KR"

  # Stripe resolves only the 8-character SWIFT/BIC and its 11-character branch-suffixed form;
  # the old 8-to-11 range let 9/10-character values save and fail later. Case is pinned because
  # only the literal `KR` was, and the location pair stays alphanumeric (Kakao is `KAKOKR22`).
  BANK_CODE_FORMAT_REGEX = /\A[A-Z]{4}KR[A-Z0-9]{2}(?:[A-Z0-9]{3})?\z/
  private_constant :BANK_CODE_FORMAT_REGEX

  # Stripe accepts 11-16 digit South Korean account numbers (verified by live
  # token probes at the boundary); keep our cap aligned so we don't reject
  # account numbers the processor would take.
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A[0-9]{11,16}\z/
  private_constant :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  # Only on write: 156 pre-existing rows carry a 9- or 10-character code, and re-validating them
  # would abort unrelated saves — including the mark_deleted! a payout-method switch performs.
  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
  validate :validate_account_number

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::KOR.alpha2
  end

  def currency
    Currency::KRW
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
end
