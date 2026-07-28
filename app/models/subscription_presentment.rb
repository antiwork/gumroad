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
  belongs_to :subscription

  validates :presentment_currency, presence: true
  validates :presentment_price_cents, numericality: { greater_than: 0, only_integer: true }
  validates :signup_exchange_rate, numericality: { greater_than: 0 }
  validate :presentment_currency_is_supported

  # The fixed amount is authoritative for what the buyer is charged, so a renewal must never
  # recompute it from a current rate. This is the single reader the charge path should use.
  def fixed_presentment_price_cents
    presentment_price_cents
  end

  # Drift between what the buyer's fixed amount was worth at signup and what it is worth now.
  # Reporting only — it must not feed the charge. Positive means the fixed amount is worth
  # more USD today than at signup (Gumroad gains); negative means it is worth less (Gumroad
  # absorbs the loss).
  def usd_drift_cents(current_exchange_rate)
    return 0 if current_exchange_rate.blank? || current_exchange_rate.to_d.zero?

    usd_at_signup = presentment_price_cents / signup_exchange_rate.to_d
    usd_now = presentment_price_cents / current_exchange_rate.to_d
    (usd_now - usd_at_signup).round
  end

  private
    def presentment_currency_is_supported
      return if presentment_currency.blank?
      return if CURRENCY_CHOICES.key?(presentment_currency.to_s.downcase)

      errors.add(:presentment_currency, "is not a supported currency")
    end
end
