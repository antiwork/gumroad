# frozen_string_literal: true

class PurchaseOfferCodeDiscount < ApplicationRecord
  belongs_to :purchase, optional: true
  belongs_to :offer_code, optional: true

  validates :purchase, presence: true, uniqueness: true
  validates :offer_code, presence: true
  validates :offer_code_amount, presence: true
  validates :pre_discount_minimum_price_cents, presence: true

  alias_attribute :duration_in_billing_cycles, :duration_in_months
end
