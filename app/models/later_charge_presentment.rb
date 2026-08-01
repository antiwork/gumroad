# frozen_string_literal: true

# The buyer-local currency and amount a LATER charge is billed in — fixed when the amount is
# agreed at checkout, and honoured on every charge afterwards until it is deliberately re-fixed.
#
# "Later charge" means any charge that happens after the buyer leaves checkout, which is what
# every product type in gumroad-private#1322 has in common:
#
#   * a membership renewal            (owner: Subscription)
#   * an installment plan's 2nd..nth  (owner: Subscription — installment plans are subscriptions
#                                      internally, flagged by Subscription#is_installment_plan)
#   * a preorder charged on release   (owner: Preorder)
#   * a commission balance payment    (owner: Commission)
#
# Why the amount is STORED rather than re-converted per charge (product decision,
# gumroad-private#1322): a buyer who subscribes at EUR 9.99/month pays EUR 9.99 every month,
# exactly as a USD buyer pays USD 10 every month. Looking the rate up at charge time would move
# their bill up and down with the market, which is not something a buyer consents to and not
# something any other Gumroad buyer experiences. The seller's proceeds absorb the drift.
#
# It is also the only answer the rails allow. A Stripe FX quote can be locked for at most 24
# hours, so a charge weeks or months later cannot reuse the quote from checkout — the choice is
# between a fixed amount and an amount that moves. And UPI Autopay forces the same answer
# independently: Indian merchant-initiated transactions must register a fixed maximum amount at
# mandate setup, so a floating amount cannot be represented on that rail at all.
#
# Rows are IMMUTABLE and effective-dated — one per fixing, not one per owner. When a direct-listed
# required-currency renewal changes price, Purchase::LaterChargePresentmentService appends a row
# from that renewal's current product-currency terms. Other plan changes retain the canonical-USD
# fallback because no authoritative buyer-currency terms exist after checkout.
class LaterChargePresentment < ApplicationRecord
  include CurrencyHelper

  # Every type allowed to own a fixed buyer-currency amount, and the association each one reads
  # it back through. Enumerated rather than left open because a type not in this list has no
  # later-charge path for the amount to apply to, so a row against it would be inert — it would
  # look like the buyer had a local price while every charge silently took canonical dollars.
  OWNER_TYPES = %w[Subscription Preorder Commission].freeze

  belongs_to :owner, polymorphic: true

  # Stored lowercase so a currency comparison against any other presentment table matches.
  # charge_presentments rows are lowercase and Checkout::BuyerCurrencyEligibility only ever
  # produces lowercase, so a mixed-case row here would silently fail to join with either.
  normalizes :presentment_currency, with: -> (currency) { currency&.downcase }

  validates :owner_type, inclusion: { in: OWNER_TYPES, message: "does not have later charges to present" }
  validates :processor, presence: true
  validates :presentment_currency, presence: true
  validates :presentment_price_cents, numericality: { greater_than: 0, only_integer: true }
  validates :canonical_price_cents, numericality: { greater_than: 0, only_integer: true }
  validates :signup_currency_units_per_usd, numericality: { greater_than: 0 }
  validates :effective_from, presence: true
  validate :presentment_currency_is_chargeable

  # Rows are the historical record the seller-side drift is measured against, so once written they
  # must not move. A re-fixing writes a new row; see the class comment.
  before_update { raise ActiveRecord::ReadOnlyRecord, "later charge presentments are immutable — write a new fixing instead" }

  # The fixing a charge for `owner` should read: the most recent one that has taken effect.
  # Never a future-dated row (a scheduled plan change can be written ahead of time), and never
  # an older one just because it was created later.
  def self.current_for(owner)
    where(owner:)
      .where(effective_from: ..Time.current)
      .order(effective_from: :desc, id: :desc)
      .first
  end

  # The canonical US-dollar figure a fixing is anchored to: the plan's own price for one period,
  # with tax, tip and shipping taken back out.
  #
  # Defined once here because the write path and the charge path must anchor on exactly the same
  # figure. `purchase.price_cents` cannot be that figure: Purchase#prepare_for_charge! folds
  # excluded seller tax and shipping into it before the charge, so anchoring on it made a member
  # moving house or a VAT rate change look identical to a plan change, and every renewal after
  # that quietly reverted to US dollars. The components removed here are the same ones a renewal
  # re-converts at today's rate (Purchase::LaterChargePresentmentService), so what is left is precisely
  # the part that is supposed to stay fixed.
  def self.canonical_price_cents_for(purchase)
    purchase.total_transaction_cents.to_i -
      purchase.tip&.value_usd_cents.to_i -
      purchase.tax_cents.to_i -
      purchase.gumroad_tax_cents.to_i -
      purchase.shipping_cents.to_i
  end

  # What the buyer's fixed amount was worth in USD cents when it was fixed.
  def usd_cents_when_fixed
    usd_cents_for(signup_currency_units_per_usd)
  end

  # Drift between what the buyer's fixed amount was worth when it was fixed and what it is
  # worth at `current_units_per_usd`, in USD cents. Reporting only — it must never feed a
  # charge. Positive means the fixed amount is worth more USD now (the seller gains); negative
  # means it is worth less (the seller absorbs the shortfall).
  #
  # `current_units_per_usd` must be in the same direction as the stored rate: units of the
  # presentment currency per 1 US dollar, which is what CurrencyHelper#get_rate returns. A
  # Stripe FX quote's fx_rate is the reciprocal and must not be passed here.
  #
  # Returns nil, not 0, when the current rate is missing or unusable. A zero drift is a real
  # and common answer (the rate did not move), so returning 0 for "cannot tell" would make an
  # unanswerable row indistinguishable from a stable one in any report that sums or averages
  # these, and would understate the seller-side drift this record exists to measure.
  def usd_drift_cents(current_units_per_usd)
    usd_now = usd_cents_for(current_units_per_usd)
    return nil if usd_now.nil?

    usd_now - usd_cents_when_fixed
  end

  private
    # Converts the stored presentment amount to USD cents at `units_per_usd`. Delegating to
    # CurrencyHelper#get_usd_cents rather than dividing here is what keeps single-unit
    # currencies correct: a yen amount is stored in whole yen, not in hundredths of a yen, so a
    # bare division is off by a factor of 100 for JPY (1,500 yen at 157 per dollar is 955 USD
    # cents, not 10).
    def usd_cents_for(units_per_usd)
      return nil if units_per_usd.blank?

      # `exception: false` because this method promises nil for an unusable rate, and the rate can
      # arrive as a String from CurrencyHelper#get_rate (which reads a cache) — a garbage cached
      # value should make a reporting figure unanswerable, not raise out of a report.
      rate = BigDecimal(units_per_usd.to_s, exception: false)
      return nil if rate.nil? || !rate.positive?

      get_usd_cents(presentment_currency, presentment_price_cents, rate:)
    end

    # A row the charge path could never use is worse than no row: the owner would look like it
    # had a buyer-currency price while every later charge silently took canonical dollars. So
    # this mirrors the currency gates the charge path itself applies, rather than only checking
    # that the currency exists.
    def presentment_currency_is_chargeable
      return if presentment_currency.blank?

      currency = presentment_currency.to_s.downcase

      unless CURRENCY_CHOICES.key?(currency)
        errors.add(:presentment_currency, "is not a supported currency")
        return
      end

      # US dollars are the canonical currency every Gumroad charge is denominated in, so there is
      # nothing to present: Checkout::BuyerCurrencyEligibility falls back on
      # :canonical_buyer_currency for a US buyer and writes no presentment rows at all.
      if currency == Currency::USD
        errors.add(:presentment_currency, "is the canonical currency, so there is nothing to present")
        return
      end

      # Stripe's minor-unit convention has to match ours or the amount we send is off by a factor
      # of 100 — the same gate Checkout::BuyerCurrencyEligibility#decision applies before it will
      # quote a currency at all.
      #
      # This gate is also what keeps the USD figures above correct. Korean won is the one
      # supported currency where Gumroad's stored minor unit (1/100 won, see
      # config/initializers/money.rb) disagrees with both Stripe (whole won) and
      # config/currencies.json (which does not flag KRW single_unit, so CurrencyHelper reads a
      # KRW amount as hundredths). A stored KRW fixing would therefore be unchargeable AND
      # report a USD value 100x too small; rejecting the row here is what makes both impossible.
      # Japanese yen, the only supported currency stored in whole units, is flagged single_unit
      # and so converts correctly.
      unless StripeChargeProcessor.charge_minor_units_compatible?(currency)
        errors.add(:presentment_currency, "cannot be charged in minor units by Stripe")
      end
    end
end
