# frozen_string_literal: true

# Mirror the seller's USD ending onto the buyer-currency quote at mint time
# ($9.99 → €8,99, not €8,53). Use the converted TOTAL's ending (tax included),
# not the bare product price.
#
# Mint time, not charge time: the charged amount must be the total the buyer
# confirmed. Seller proceeds/tax/shipping stay canonical USD; the delta lands
# on Gumroad (charge_presentments.rounding_delta_cents).
#
# Direction is NEAREST, never ceiling — always-up is a price rise on
# international buyers, not a rounding side effect.
class Checkout::PresentmentRounding
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents, :delta_cents, keyword_init: true) do
    def rounded?
      !delta_cents.zero?
    end
  end

  # How far the quoted amount may sit from the true converted amount, by how large it is.
  # Mirroring the ending can ask for a move of up to half a major unit (49 cents), which is
  # a rounding error on a €40 cart and a fifth of the price on a €2,20 one. When the move
  # the seller's ending would need is outside this cap we do not round at all: the buyer
  # sees and pays the exact converted amount, which is today's behaviour.
  PERCENT_CAPS = [
    { below_minor: 5_00, max_percent: 10 },
    { below_minor: 25_00, max_percent: 6 },
    { below_minor: nil, max_percent: 3 },
  ].freeze

  # Zero-decimal currencies (¥, ₩ …) have no cents, so a USD ending cannot be copied into
  # them literally — there is no ¥8,99. The ending is mirrored one place up instead: it is
  # read as a position inside a hundred units, so a $9.99 price quotes ¥1,499 (one below a
  # round hundred, the same shape as one below a round unit) and a $10 price quotes a round
  # ¥1,500. Below the cap this leaves the amount alone, which is why small yen carts quote
  # the exact converted amount.
  ZERO_DECIMAL_STEP = 100
  ZERO_DECIMAL_MAX_PERCENT = 3

  # On by default for buyer-local-currency sellers (own opt-out). Fee-waived
  # sales are excluded: the delta is absorbed from Gumroad's share, and a
  # waived Stripe-Connect charge can leave nothing — rounding down would
  # come out of the seller.
  def self.enabled_for?(seller)
    Checkout::BuyerCurrencyEligibility.seller_enabled?(seller) &&
      !seller.disable_buyer_currency_rounding? &&
      !seller.waive_gumroad_fee_on_new_sales?
  end

  # Zero delta = charge the exact converted amount. Unsafe paths return that
  # rather than raise — checkout must not fail over a cosmetic ending.
  #
  # Ending comes from canonical_total_cents (USD). max_downward_cents is
  # Gumroad's presentment-currency share at quote time (BuyerCurrencyQuote);
  # it is a prediction — PresentmentOrchestrator re-checks the real fee and
  # refuses if a waiver landed between quote and charge.
  def self.round(presentment_total_cents:, canonical_total_cents:, currency:, max_downward_cents:)
    new(presentment_total_cents:, canonical_total_cents:, currency:, max_downward_cents:).round
  end

  # Floor of what a round-down may take: flat Gumroad fee on price+tips only
  # (not fixed fee, processor fees, remitted tax). Zero when the seller pays
  # no percentage fee.
  #
  # Tips are in the fee base (customizable price → Purchase#price_cents).
  # Brazilian Stripe Connect zeroes fee_cents in calculate_fees — they are
  # otherwise buyer-currency eligible, so without the early return the cap
  # would claim absorption that does not exist.
  def self.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents:, merchant_account: nil)
    return 0 if merchant_account&.is_a_brazilian_stripe_connect_account?

    fee_per_thousand = seller.gumroad_fee_per_thousand.to_i
    return 0 unless fee_per_thousand.positive?

    canonical_price_and_tip_cents.to_i * fee_per_thousand / 1000
  end

  attr_reader :presentment_total_cents, :canonical_total_cents, :currency, :max_downward_cents

  def initialize(presentment_total_cents:, canonical_total_cents:, currency:, max_downward_cents:)
    @presentment_total_cents = presentment_total_cents.to_i
    @canonical_total_cents = canonical_total_cents.to_i
    @currency = currency.to_s.downcase
    @max_downward_cents = [max_downward_cents.to_i, 0].max
  end

  def round
    unrounded = Result.new(presentment_total_cents:, delta_cents: 0)
    return unrounded unless presentment_total_cents.positive?
    return unrounded unless canonical_total_cents.positive?
    # Below one major unit there is no ending worth mirroring, and rounding down could
    # take the charge under a processor minimum.
    return unrounded if presentment_total_cents < subunit_to_unit(currency)

    # Already carries the seller's ending: leave it exactly where it is.
    return unrounded if candidates.include?(presentment_total_cents)

    target = nearest_allowed_target
    return unrounded if target.nil?

    Result.new(presentment_total_cents: target, delta_cents: target - presentment_total_cents)
  rescue StandardError => e
    # A cosmetic price ending must never be able to break a checkout: fall back to the
    # exact converted amount, which is the behaviour every charge had before this existed.
    ErrorNotifier.notify(e, context: { presentment_total_cents:, canonical_total_cents:, currency: })
    Result.new(presentment_total_cents:, delta_cents: 0)
  end

  private
    def zero_decimal?
      subunit_to_unit(currency) == 1
    end

    # Ties (an amount exactly between the occurrence below and the one above) go to the
    # lower one: given no reason to prefer either, charge the buyer less. When the nearer
    # occurrence is out of bounds (usually because Gumroad cannot absorb that much of a
    # round-down) the other one is used rather than giving up on rounding altogether.
    def nearest_allowed_target
      candidates
        .select { |candidate| candidate.positive? && allowed?(candidate - presentment_total_cents) }
        .min_by { |candidate| [(candidate - presentment_total_cents).abs, candidate] }
    end

    # The amounts in the buyer's currency that carry the seller's ending: the occurrence
    # inside the amount's own slot plus the ones either side, so the nearest is found even
    # when the amount sits just above or just below a slot boundary.
    def candidates
      slot = presentment_total_cents / target_step

      ((slot - 1)..(slot + 1)).map { |index| index * target_step + target_ending }
    end

    # How wide the repeating window the ending sits inside is. For an ordinary two-decimal
    # currency that is one major unit, so the ending recurs every €1. For a zero-decimal
    # currency it is a hundred units, because the ending is mirrored one place up (see
    # ZERO_DECIMAL_STEP).
    def target_step
      zero_decimal? ? ZERO_DECIMAL_STEP : subunit_to_unit(currency)
    end

    # The seller's own ending, expressed in the buyer currency's units. The cents of the
    # USD total are a position inside a hundred, rescaled to a position inside the window
    # above — 99 cents becomes 99 yen out of every hundred, or 99 euro cents out of every
    # euro.
    def target_ending
      canonical_total_cents % subunit_to_unit(Currency::USD) * target_step / subunit_to_unit(Currency::USD)
    end

    def allowed?(delta_cents)
      return false if delta_cents.zero?
      # Rounding down beyond what Gumroad can absorb would come out of the seller's money.
      return false if delta_cents.negative? && delta_cents.abs > max_downward_cents

      delta_cents.abs * 100 <= presentment_total_cents * max_percent
    end

    def max_percent
      return ZERO_DECIMAL_MAX_PERCENT if zero_decimal?

      PERCENT_CAPS.find { |cap| cap[:below_minor].nil? || presentment_total_cents < cap[:below_minor] }.fetch(:max_percent)
    end
end
