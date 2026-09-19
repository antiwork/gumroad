# frozen_string_literal: true

class BosniaAndHerzegovinaBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "BA"

  # Stripe's BA rail resolves the 8-character BIC or the 11-character branch-suffixed form only, so a
  # 9- or 10-character value saved and then failed the async bank sync with no error at save time.
  BANK_CODE_FORMAT_REGEX = /^[a-zA-Z0-9]{8}([a-zA-Z0-9]{3})?$/
  private_constant :BANK_CODE_FORMAT_REGEX

  alias_attribute :bank_code, :bank_number

  # Only on write: live rows hold 9- and 10-character codes from before this check, and re-validating
  # them would abort unrelated saves — including the mark_deleted! a payout-method switch performs
  # after the Stripe account is already gone.
  validate :validate_bank_code, if: -> { new_record? || will_save_change_to_bank_number? }
  validate :validate_account_number, if: -> { Rails.env.production? }

  def routing_number
    "#{bank_code}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::BIH.alpha2
  end

  def currency
    Currency::BAM
  end

  def account_number_visual
    "BA******#{account_number_last_four}"
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
end
