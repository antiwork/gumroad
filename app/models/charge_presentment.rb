# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, presence: true

  # fx_rate is the rate the buyer was quoted — Stripe's spread already priced in; the fee-free
  # base_rate is deliberately not persisted, so the spread is not reconstructible from these
  # rows (see StripeFxQuote#parsed_rate and the note on Balance#holding_currency).

  # Stripe rows: quote-backed (all three quote columns), direct-listed (all three
  # blank), or cached-rate native EUR presentment (fx_rate only). A quote id without
  # expiry and rate is never valid.
  validate :stripe_fx_quote_fields_consistent, if: :stripe_processor?
  validates :presentment_total_cents, :presentment_gumroad_amount_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  # Signed on purpose: negative when mirroring the seller's price ending lowered the
  # buyer's total, positive when it raised it. Zero on every charge that was not rounded.
  validates :rounding_delta_cents, numericality: { only_integer: true }

  private
    def stripe_processor?
      processor == StripeChargeProcessor.charge_processor_id
    end

    def stripe_fx_quote_fields_consistent
      quoted = stripe_fx_quote_id.present? || stripe_fx_quote_expires_at.present?
      if quoted
        return if stripe_fx_quote_id.present? && stripe_fx_quote_expires_at.present? && fx_rate.present?

        errors.add(:base, "Stripe FX quote id, expiry, and rate must all be present together")
      elsif fx_rate.present? && presentment_currency.to_s.downcase != Currency::EUR
        errors.add(:base, "Cached-rate presentment without a Stripe FX quote is only valid for EUR")
      end
    end
end
