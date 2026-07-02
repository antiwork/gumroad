# frozen_string_literal: true

class PurchasePresentment < ApplicationRecord
  belongs_to :purchase
  belongs_to :charge_presentment, optional: true

  validates :processor, :presentment_currency, presence: true
  validates :charge_presentment, presence: true, if: :stripe_processor?
  validates :presentment_price_cents,
            :presentment_tip_cents,
            :presentment_seller_tax_cents,
            :presentment_gumroad_tax_cents,
            :presentment_shipping_cents,
            :presentment_total_cents,
            :presentment_gumroad_amount_cents,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validate :presentment_components_sum_to_total

  private
    def stripe_processor?
      processor == StripeChargeProcessor.charge_processor_id
    end

    def presentment_components_sum_to_total
      components = [
        presentment_price_cents,
        presentment_tip_cents,
        presentment_seller_tax_cents,
        presentment_gumroad_tax_cents,
        presentment_shipping_cents,
      ]
      return if components.any?(&:nil?) || presentment_total_cents.nil?

      errors.add(:presentment_total_cents, "must equal the sum of presentment components") if components.sum != presentment_total_cents
    end
end
