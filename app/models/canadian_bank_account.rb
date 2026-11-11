# frozen_string_literal: true

class CanadianBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "CANADIAN"

  INSTITUTION_NUMBER_FORMAT_REGEX = /^\d{3}$/

  TRANSIT_NUMBER_FORMAT_REGEX = /^\d{5}$/

  # Stripe's CA rail takes digits only, at most 12 (no minimum probed, so none enforced).
  ACCOUNT_NUMBER_FORMAT_REGEX = /\A\d{1,12}\z/

  private_constant :INSTITUTION_NUMBER_FORMAT_REGEX, :TRANSIT_NUMBER_FORMAT_REGEX, :ACCOUNT_NUMBER_FORMAT_REGEX

  alias_attribute :institution_number, :bank_number
  alias_attribute :transit_number, :branch_code

  validate :validate_institution_number
  validate :validate_transit_number
  # Legacy over-long numbers must not block unrelated saves, including payout-method deletion.
  validate :validate_account_number, if: -> { will_save_change_to_account_number? }

  def routing_number
    "#{transit_number}-#{institution_number}"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def country
    Compliance::Countries::CAN.alpha2
  end

  def currency
    Currency::CAD
  end

  def to_hash
    super.merge(
      transit_number:,
      institution_number:
    )
  end

  private
    def validate_institution_number
      errors.add :base, "The institution number is invalid." unless INSTITUTION_NUMBER_FORMAT_REGEX.match?(institution_number)
    end

    def validate_transit_number
      errors.add :base, "The transit number is invalid." unless TRANSIT_NUMBER_FORMAT_REGEX.match?(transit_number)
    end

    def validate_account_number
      errors.add :base, "The account number is invalid." unless ACCOUNT_NUMBER_FORMAT_REGEX.match?(account_number_decrypted.to_s)
    end
end
