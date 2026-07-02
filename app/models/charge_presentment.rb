# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, presence: true
  # The quote columns are nullable at the database level so quoteless rows (local payment
  # methods where the quote cannot lock, Phase 3 PayPal) can reuse this table; every Stripe
  # row created today is quote-backed, so presence is enforced here instead.
  validates :stripe_fx_quote_id, :stripe_fx_quote_expires_at, :fx_rate, presence: true, if: :stripe_processor?
  validates :presentment_total_cents, :presentment_gumroad_amount_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  private
    def stripe_processor?
      processor == StripeChargeProcessor.charge_processor_id
    end
end
