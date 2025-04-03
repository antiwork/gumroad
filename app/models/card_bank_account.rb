# frozen_string_literal: true

class CardBankAccount < BankAccount
  BANK_ACCOUNT_TYPE = "CARD"

  belongs_to :credit_card, optional: true

  validates :credit_card, presence: true
  validate :validate_credit_card_is_funded_by_debit
  validate :validate_credit_card_is_issued_by_a_united_states_issuer

  # Only on create because we already have invalid data in the DB.
  # TODO: Clean up data and apply the validation on all actions when possible.
  validate :validate_credit_card_is_not_fraudy, on: :create

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  def routing_number
    credit_card.card_type.capitalize
  end

  def account_number_visual
    credit_card.visual
  end

  def account_number
    credit_card.visual
  end

  def account_number_last_four
    ChargeableVisual.get_card_last4(account_number)
  end

  def account_holder_full_name
    credit_card.visual
  end

  def country
    Compliance::Countries::USA.alpha2
  end

  def currency
    Currency::USD
  end

  private
    def validate_credit_card_is_not_fraudy
      errors.add :base, "Your payout card must be a US debit card." if credit_card.card_type == "visa" && %w[5860 0559].include?(account_number_last_four)
    end

    def validate_credit_card_is_funded_by_debit
      errors.add :base, "Your payout card must be a US debit card." unless credit_card.funding_type == ChargeableFundingType::DEBIT
    end

    def validate_credit_card_is_issued_by_a_united_states_issuer
      errors.add :base, "Your payout card must be a US debit card." unless credit_card.card_country == Compliance::Countries::USA.alpha2
    end
end
