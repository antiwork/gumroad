# frozen_string_literal: true

# Rounds a buyer-currency total to a price ending a human would plausibly have chosen
# (€8,49 instead of €8,53), at the moment the quote is minted.
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
# Direction is NEAREST target only, never ceiling. Measured against 2,159 real
# charge_presentments amounts (July 2026): a nearest rule moves the buyer's total by
# 0.90% on average in absolute terms and is very slightly in the buyer's favour on
# balance (signed mean -0.13%, 1,170 down vs 953 up), whereas a ceiling rule on the same
# grids and the same amounts is a +2.06% average price increase (p50 +1.27%, p90 +5.20%).
# A ceiling rule is therefore a price rise on international buyers wearing a rounding
# algorithm's clothes; if we ever want that spread we should take it explicitly as a
# pricing decision, not as a side effect of making prices look nicer.
class Checkout::PresentmentRounding
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents, :delta_cents, keyword_init: true) do
    def rounded?
      !delta_cents.zero?
    end
  end

  # Target price endings, by how large the amount is. Each band is a repeating grid:
  # `endings_minor` are the offsets inside each `step_minor`-wide slot that count as a
  # good-looking price. So the $5-$25 band targets every whole unit minus one and minus
  # fifty-one cents (7.49, 7.99, 8.49 …), and the $100+ band targets every five units
  # minus a cent (104.99, 109.99 …), where a coarser grid is still a small move.
  #
  # The grids are deliberately finer than the price-ending research alone would suggest,
  # because the grid — not the percentage cap — is what bounds how far any single amount
  # can move. With only .99 to aim at below $5, a €1,22 conversion has nowhere good to go
  # (€0,99 is −19%, €1,49 is +20%), and a rounding rule that can move a small price by a
  # fifth is not one we should ship. Each band's worst case (half its widest gap) is at
  # most a few percent of the smallest amount in that band.
  #
  # `max_percent` is how far the rounded amount may sit from the true converted amount.
  # When no target inside the cap fits, we do not round at all — the buyer sees and pays
  # the exact converted amount, which is what happens today.
  BANDS = [
    { below_minor: 5_00, step_minor: 100, endings_minor: [29, 49, 79, 99], max_percent: 8 },
    { below_minor: 25_00, step_minor: 100, endings_minor: [49, 99], max_percent: 6 },
    { below_minor: 100_00, step_minor: 100, endings_minor: [99], max_percent: 3 },
    { below_minor: nil, step_minor: 500, endings_minor: [499], max_percent: 3 },
  ].freeze

  # Zero-decimal currencies (¥, ₩ …) have no cents to make charming, so the good-looking
  # amount is a round one: ¥1,500 rather than ¥1,483. We pick the coarsest of these grids
  # whose worst case still fits the percentage cap, so small yen amounts round to tens and
  # large ones to thousands.
  ZERO_DECIMAL_STEPS = [10, 50, 100, 500, 1_000, 5_000].freeze
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
  def self.round(presentment_total_cents:, currency:, max_downward_cents:)
    new(presentment_total_cents:, currency:, max_downward_cents:).round
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

    fee_per_thousand = (seller.custom_fee_per_thousand.presence || Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND).to_i
    return 0 unless fee_per_thousand.positive?

    canonical_price_and_tip_cents.to_i * fee_per_thousand / 1000
  end

  attr_reader :presentment_total_cents, :currency, :max_downward_cents

  def initialize(presentment_total_cents:, currency:, max_downward_cents:)
    @presentment_total_cents = presentment_total_cents.to_i
    @currency = currency.to_s.downcase
    @max_downward_cents = [max_downward_cents.to_i, 0].max
  end

  def round
    unrounded = Result.new(presentment_total_cents:, delta_cents: 0)
    return unrounded unless presentment_total_cents.positive?
    # Below one major unit there is no ending worth aiming at, and rounding down could
    # take the charge under a processor minimum.
    return unrounded if presentment_total_cents < subunit_to_unit(currency)

    # Already a good-looking price: leave it exactly where it is. Without this an amount
    # sitting on a target would be pulled to a neighbouring one, since the target it is
    # already on is a zero-distance move and therefore not a move at all.
    return unrounded if candidates.include?(presentment_total_cents)

    target = nearest_allowed_target
    return unrounded if target.nil?

    Result.new(presentment_total_cents: target, delta_cents: target - presentment_total_cents)
  rescue StandardError => e
    # A cosmetic price ending must never be able to break a checkout: fall back to the
    # exact converted amount, which is the behaviour every charge had before this existed.
    ErrorNotifier.notify(e, context: { presentment_total_cents:, currency: })
    Result.new(presentment_total_cents:, delta_cents: 0)
  end

  private
    def zero_decimal?
      subunit_to_unit(currency) == 1
    end

    # Ties (an amount exactly between two targets) go to the lower one: given no reason
    # to prefer either, charge the buyer less. When the nearest target is out of bounds
    # (usually because Gumroad cannot absorb that much of a round-down) the next-nearest
    # allowed one is used rather than giving up on rounding altogether.
    def nearest_allowed_target
      candidates
        .select { |candidate| candidate.positive? && allowed?(candidate - presentment_total_cents) }
        .min_by { |candidate| [(candidate - presentment_total_cents).abs, candidate] }
    end

    def candidates
      zero_decimal? ? zero_decimal_candidates : banded_candidates
    end

    # Walks the slots either side of the amount so the nearest target is found even when
    # the amount sits just above or just below a slot boundary.
    def banded_candidates
      step = band.fetch(:step_minor)
      slot = presentment_total_cents / step

      ((slot - 1)..(slot + 1)).flat_map do |index|
        band.fetch(:endings_minor).map { |ending| index * step + ending }
      end
    end

    # Picks the coarsest round-number grid whose worst case still fits the percentage
    # cap, then offers the multiples either side of the amount. A step is only usable if
    # half of it (the furthest the amount can be from a multiple) is inside the cap.
    def zero_decimal_candidates
      allowance = presentment_total_cents * ZERO_DECIMAL_MAX_PERCENT / 100.0
      step = ZERO_DECIMAL_STEPS.select { |candidate| candidate / 2.0 <= allowance }.max
      return [] if step.nil?

      [presentment_total_cents / step, presentment_total_cents / step + 1].map { _1 * step }
    end

    def allowed?(delta_cents)
      return false if delta_cents.zero?
      # Rounding down beyond what Gumroad can absorb would come out of the seller's money.
      return false if delta_cents.negative? && delta_cents.abs > max_downward_cents

      max_percent = zero_decimal? ? ZERO_DECIMAL_MAX_PERCENT : band.fetch(:max_percent)
      delta_cents.abs * 100 <= presentment_total_cents * max_percent
    end

    def band
      @band ||= BANDS.find { |candidate| candidate[:below_minor].nil? || presentment_total_cents < candidate[:below_minor] }
    end
end
