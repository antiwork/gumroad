# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, presence: true
  # Stripe rows come in two shapes. Card-path buyer presentment locks a Stripe FX quote,
  # so those rows carry all three quote columns. Method-forced local payment methods
  # (iDEAL/Bancontact) charging a product already priced in the forced currency have no
  # FX conversion at all — no quote exists by design, so all three columns stay null.
  # Enforce all-or-none so a partially persisted quote can never slip through.
  validate :stripe_fx_quote_fields_all_or_none, if: :stripe_processor?
  validates :presentment_total_cents, :presentment_gumroad_amount_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

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
