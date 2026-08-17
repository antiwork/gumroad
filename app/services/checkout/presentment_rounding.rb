# frozen_string_literal: true

# Rounds a buyer-currency total so it keeps the price ending the seller chose in USD:
# a $9.99 cart quotes €8,99 rather than €8,53, and a $10 cart quotes €9 rather than €8,53.
# This happens at the moment the quote is minted.
#
# Mirroring the seller's own ending, rather than picking from a menu of "good" endings, is
# the rule Gumroad wants: the seller decided what their price should look like, and a buyer
# paying in euros should see the same decision expressed in euros. It also means we never
# have to defend a chosen set of endings — the ending is whatever the seller already picked.
# The ending mirrored is the one on the USD total being converted, so a cart with tax keeps
# the total's ending (the .49 of an $11.49 total), not the bare product price's.
#
# Why quote-mint time and not charge time: the buyer decides against the amount the
# checkout shows them. Rounding after that decision — on the way to the processor —
# changes the amount charged without changing the amount displayed, which both misses
# the entire point of a nicer price and breaks the invariant the buyer-currency feature
# is built around (the charged amount is exactly the total the buyer confirmed). So the
# rounding happens once, before the quote is signed, and the rounded amount is what is
# displayed, itemized, locked into the quote token, and charged.
#
# The seller's proceeds, tax, shipping, balances and payouts are all canonical USD
# amounts and are untouched by this: the whole rounding difference lands on Gumroad's
# side of the presentment charge (see Charge::PresentmentOrchestrator), and is recorded
# as charge_presentments.rounding_delta_cents so it can be monitored alongside
# foreign-exchange drift.
#
# Direction is NEAREST occurrence of that ending, never ceiling. Measured against 2,159
# real charge_presentments amounts (July 2026, on an earlier version of this rule that
# aimed at a fixed menu of endings): a nearest rule was very slightly in the buyer's
# favour on balance (signed mean -0.13%), whereas always rounding up to the next
# occurrence was a +2.06% average price increase. The grids have changed since, but the
# asymmetry has not: always-up is a price rise on international buyers wearing a rounding
# algorithm's clothes. If we ever want that spread we should take it explicitly as a
# pricing decision, not as a side effect of making prices look nicer.
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

  # Rounding rides along with the seller's buyer-local-currency setup and is on by
  # default for those sellers, with its own opt-out. Opt-in would give us a
  # self-selected minority of sellers and no read on whether the feature does anything.
  #
  # Fee-waived sales are excluded. The rounding difference is absorbed out of Gumroad's
  # share of the charge, so there has to BE a share: on a sale where Gumroad's fee is
  # waived (Gumroad Day, or the per-seller waiver flag) a Stripe-Connect seller's charge
  # can leave Gumroad nothing, and rounding down would have to come out of the seller's
  # money. Those sales quote the exact converted amount instead.
  def self.enabled_for?(seller)
    Checkout::BuyerCurrencyEligibility.seller_enabled?(seller) &&
      !seller.disable_buyer_currency_rounding? &&
      !seller.waive_gumroad_fee_on_new_sales?
  end

  # Returns the amount to quote and how far it moved. A zero delta means "charge the
  # exact converted amount" — every path that cannot round safely returns that rather
  # than raising, because a checkout must never fail over a cosmetic price ending.
  #
  # canonical_total_cents is the USD total being converted, and it is what supplies the
  # ending to mirror: its cents (99 for a $9.99 cart, 0 for a $10 one) are the ending the
  # quoted amount is pulled onto.
  #
  # max_downward_cents is how much of the charge Gumroad is known to be able to give up:
  # rounding DOWN is absorbed out of Gumroad's share of the charge, and the seller's
  # proceeds must come out identical either way, so the amount can never fall further
  # than that. Callers pass the presentment-currency value of the share they can prove
  # exists at quote time (see Checkout::BuyerCurrencyQuote).
  #
  # This cap is a prediction, not a guarantee: a fee waiver can begin between the quote and
  # the charge, leaving no Gumroad share behind the round-down this sized. That is why
  # Charge::PresentmentOrchestrator re-checks the reduction against the fee actually
  # computed on the purchases and refuses the charge if the fee no longer covers it.
  def self.round(presentment_total_cents:, canonical_total_cents:, currency:, max_downward_cents:)
    new(presentment_total_cents:, canonical_total_cents:, currency:, max_downward_cents:).round
  end

  # The part of the charge Gumroad is guaranteed to be holding, and so the most a
  # round-down may take. It counts only the flat Gumroad fee on the cart's price and tips,
  # deliberately ignoring everything else Gumroad ends up with (the fixed fee, processor
  # fees, taxes we remit) — a floor is what this needs to be, not an accurate total.
  # Returns 0 when the seller pays no percentage fee, which keeps rounding down off for
  # those sales rather than funding it out of the seller's money.
  #
  # Tips belong in the base because Gumroad's percentage fee is charged on them: a tip
  # makes a product's price "customizable" rather than adding a line beside it, so the
  # buyer submits one tip-inclusive price, that becomes Purchase#price_cents, and
  # Purchase#calculate_fees takes its percentage from that whole amount. A tip-heavy cart
  # therefore has a proportionally larger Gumroad share, not a smaller one. The
  # presentment_rounding spec asserts this cap against the real fee calculation, so if the
  # tip ever stops being part of the fee base a test fails rather than a round-down
  # silently reaching into the seller's money.
  #
  # Brazilian Stripe Connect sellers are the exception the fee percentages cannot see:
  # Purchase#calculate_fees zeroes fee_cents outright for those accounts, so Gumroad takes
  # nothing from the charge and there is no share for a round-down to come out of. They are
  # otherwise buyer-currency eligible, so without this the cap would claim absorption
  # capacity that does not exist and the reduction would land on the seller's proceeds.
  # Those sales quote the exact converted amount instead.
  def self.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents:, merchant_account: nil)
    return 0 if merchant_account&.is_a_brazilian_stripe_connect_account?

    fee_per_thousand = (seller.custom_fee_per_thousand.presence || seller.gumroad_fee_per_thousand).to_i
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
