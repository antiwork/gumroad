# frozen_string_literal: true

# The buyer-local currency and amount a subscription is billed in, recorded once when the
# buyer signs up and then honoured for the life of the subscription.
#
# Why the amount is stored rather than converted per renewal (product decision,
# gumroad-private#1322): a buyer who subscribes at EUR 9.99/month pays EUR 9.99 every month,
# exactly as a USD buyer pays USD 10 every month. Looking the rate up at renewal time would
# move their bill up and down with the market, which is not something a subscriber consents
# to and not something any other Gumroad buyer experiences. Gumroad absorbs the drift.
#
# UPI Autopay forces the same answer independently: Indian merchant-initiated transactions
# must register a fixed maximum amount at mandate setup, so a floating renewal amount cannot
# be represented on that rail at all.
class SubscriptionPresentment < ApplicationRecord
  include CurrencyHelper

  belongs_to :subscription

  validates :presentment_currency, presence: true
  validates :presentment_price_cents, numericality: { greater_than: 0, only_integer: true }
  validates :signup_exchange_rate, numericality: { greater_than: 0 }
  validate :presentment_currency_is_chargeable

  # The fixed amount is authoritative for what the buyer is charged, so a renewal must never
  # recompute it from a current rate. This is the single reader the charge path should use:
  # naming it explicitly means a future renewal change that reaches for a live rate has to
  # bypass an obviously-named method rather than quietly pick a different one.
  def fixed_presentment_price_cents
    presentment_price_cents
  end

  # What the buyer's fixed amount was worth in USD cents at signup.
  def usd_cents_at_signup
    usd_cents_for(signup_exchange_rate)
  end

  # What the buyer's fixed amount is worth in USD cents at `current_exchange_rate`.
  def usd_cents_at_rate(current_exchange_rate)
    usd_cents_for(current_exchange_rate)
  end

  # Drift between what the buyer's fixed amount was worth at signup and what it is worth at
  # `current_exchange_rate`, in USD cents. Reporting only — it must not feed the charge.
  # Positive means the fixed amount is worth more USD now than at signup (Gumroad gains);
  # negative means it is worth less (Gumroad absorbs the shortfall).
  #
  # Returns nil, not 0, when the current rate is missing or unusable. A zero drift is a real
  # and common answer (the rate did not move), so returning 0 for "cannot tell" would make an
  # unanswerable question indistinguishable from a stable one in any report that sums or
  # averages these — the reconciliation this column exists for would silently understate the
  # absorbed drift. Callers decide what to do with an unknown.
  def usd_drift_cents(current_exchange_rate)
    usd_now = usd_cents_at_rate(current_exchange_rate)
    return nil if usd_now.nil?

    usd_now - usd_cents_at_signup
  end

  private
    # Converts the stored presentment amount to USD cents at `rate`, which follows the
    # CurrencyHelper convention of units of the presentment currency per 1 USD. Delegating to
    # CurrencyHelper#get_usd_cents rather than dividing here is what keeps single-unit
    # currencies correct: a yen amount is stored in whole yen, not in hundredths of a yen, so
    # a bare division is off by a factor of 100 for JPY (¥1,500 at 157/USD is 955 USD cents,
    # not 10).
    def usd_cents_for(rate)
      return nil if rate.blank?

      rate = BigDecimal(rate.to_s)
      return nil unless rate.positive?

      get_usd_cents(presentment_currency, presentment_price_cents, rate:)
    end

    # A row that the charge path could never use is worse than no row: it would let a
    # subscription look like it has a buyer-currency price while every renewal silently
    # charged canonical USD. So this mirrors the currency gates the charge path itself
    # applies, rather than only checking that the currency exists.
    def presentment_currency_is_chargeable
      return if presentment_currency.blank?

      currency = presentment_currency.to_s.downcase

      unless CURRENCY_CHOICES.key?(currency)
        errors.add(:presentment_currency, "is not a supported currency")
        return
      end

      # USD is the canonical currency every Gumroad charge is denominated in, so there is
      # nothing to present: Checkout::BuyerCurrencyEligibility falls back on
      # :canonical_buyer_currency for a US buyer and no presentment rows are written. A USD
      # row here would claim a buyer-currency price that the charge path does not honour.
      if currency == Currency::USD
        errors.add(:presentment_currency, "is the canonical currency, so there is nothing to present")
        return
      end

      # Stripe's minor-unit convention has to match ours or the amount we send is off by a
      # factor of 100 — the same gate Checkout::BuyerCurrencyEligibility#decision applies
      # before it will quote a currency at all.
      unless StripeChargeProcessor.charge_minor_units_compatible?(currency)
        errors.add(:presentment_currency, "cannot be charged in minor units by Stripe")
      end
    end
end
