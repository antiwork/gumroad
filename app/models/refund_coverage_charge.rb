# frozen_string_literal: true

class RefundCoverageCharge < ApplicationRecord
  include CurrencyHelper

  belongs_to :user
  belongs_to :purchase
  belongs_to :refund, optional: true
  belongs_to :credit_card, optional: true

  validates :charge_cents, presence: true
  validates :charge_processor_id, presence: true

  def formatted_charge
    MoneyFormatter.format(charge_cents, charge_cents_currency&.to_sym || Currency::USD, no_cents_if_whole: true, symbol: true)
  end
end
