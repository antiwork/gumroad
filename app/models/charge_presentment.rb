# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, presence: true
  # fx_rate is the rate the buyer was quoted, including Stripe's FX fee and lock premium.
  # Stripe's fee-free base_rate is discarded in StripeFxQuote, so the spread is not
  # reconstructible from these rows — by design: the buyer pays it inside the price they
  # confirmed, and both legs of our ledger settle canonical (measured on gumroad-private#1318).
  # A settled-vs-canonical gap here is rounding_delta_cents, not FX drift. Persisting base_rate
  # to make the spread reportable was declined on that issue (antiwork/gumroad#6542).
  #
  # Stripe rows come in two shapes. Card-path buyer presentment locks a Stripe FX quote,
  # so those rows carry all three quote columns. Method-forced local payment methods
  # (iDEAL/Bancontact) charging a product already priced in the forced currency have no
  # FX conversion at all — no quote exists by design, so all three columns stay null.
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

      errors.add(:base, "Stripe FX quote fields must either all be present (quote-backed row) or all be blank (quote-less method-forced row)")
    end
end
