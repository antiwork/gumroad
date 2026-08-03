# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, presence: true

  # fx_rate is the rate the buyer was quoted — Stripe's spread already priced in; the fee-free
  # base_rate is deliberately not persisted, so the spread is not reconstructible from these
  # rows (see StripeFxQuote#parsed_rate and the note on Balance#holding_currency).

  # Stripe rows come in two shapes. Quote-backed buyer presentment carries all three quote
  # columns. Direct-listed presentment has no FX conversion, so all three stay null.
  # Enforce all-or-none so a partially persisted quote can never slip through.
  validate :stripe_fx_quote_fields_all_or_none, if: :stripe_processor?
  validates :presentment_total_cents, :presentment_gumroad_amount_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  # Signed on purpose: negative when mirroring the seller's price ending lowered the
  # buyer's total, positive when it raised it. Zero on every charge that was not rounded.
  validates :rounding_delta_cents, numericality: { only_integer: true }

  private
    def stripe_processor?
      processor == StripeChargeProcessor.charge_processor_id
    end

    def stripe_fx_quote_fields_all_or_none
      quote_fields = [stripe_fx_quote_id, stripe_fx_quote_expires_at, fx_rate]
      return if quote_fields.all?(&:present?) || quote_fields.all?(&:blank?)

      errors.add(:base, "Stripe FX quote fields must either all be present (quote-backed row) or all be blank (quote-less direct-listed row)")
    end
end
