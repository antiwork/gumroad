# frozen_string_literal: true

# Pre-charge signal for card-testing cash-out rings (the "money net" of the daily
# chargeback-ring scan, moved to checkout time so it can stop sales instead of only
# pausing payouts after every sale has already been charged).
#
# Measured shape (2026-11 mills): a young seller account takes hundreds of paid sales in weeks,
# >=90% of the cards from ONE country, bought from a datacenter /16. No legitimate seller matched
# that conjunction in the production audit; young legitimate sellers with buyers from one country
# match the country clause but not the hosting-IP clause, which is why the IP dimension must stay
# in the rule.
#
# All four clauses must hold to block:
#   1. paid sales in the last 30 days >= MIN_PAID_SALES
#   2. one card_country accounts for >= DOMINANT_CARD_COUNTRY_SHARE_PCT of them
#   3. >= HOSTING_IP_SHARE_PCT of those purchases' ip_addresses fall inside HOSTING_CIDR_STRINGS
#   4. the seller account is younger than MAX_SELLER_AGE_DAYS
#
# Gated by the `chargeback_ring_signal` Flipper flag (default off — flag off means evaluate is
# never called, so there is zero behaviour change). Fail-open: any exception allows the purchase
# and records an `error` telemetry row. Every evaluation at or above MIN_PAID_SALES writes a
# telemetry row (blocked or allowed) so precision is measurable in SQL.
module Purchase::ChargebackRingSignal
  FEATURE_FLAG = :chargeback_ring_signal

  MIN_PAID_SALES = 3
  DOMINANT_CARD_COUNTRY_SHARE_PCT = 90.0
  HOSTING_IP_SHARE_PCT = 80.0
  MAX_SELLER_AGE_DAYS = 120
  WINDOW = 30.days
  # Hard bound on rows read per evaluation. The age clause already restricts evaluation to
  # accounts younger than 120 days, so this is generous slack for the biggest plausible young
  # seller; the measured mills ran ~500 paid sales in seven weeks.
  SAMPLE_LIMIT = 2_000

  # Hosting/datacenter blocks, one per line, as data so a new ring's block is a one-line change.
  # 151.240.0.0/16 is the measured block behind both 2026-11 mills.
  HOSTING_CIDR_STRINGS = %w[
    151.240.0.0/16
  ].freeze
  HOSTING_CIDRS = HOSTING_CIDR_STRINGS.map { IPAddr.new(_1) }.freeze

  DECISION_BLOCKED = "blocked"
  DECISION_ALLOWED = "allowed"
  DECISION_ERROR = "error"

  Result = Struct.new(
    :decision,
    :paid_sales,
    :dominant_card_country,
    :dominant_share_pct,
    :hosting_share_pct,
    :distinct_browsers,
    :matched_cidr,
    keyword_init: true
  ) do
    def hit? = decision == DECISION_BLOCKED
    def error? = decision == DECISION_ERROR

    # Telemetry records both sides (blocked and allowed) once a seller has enough paid sales
    # for the volume clause, so false-positive rate is measurable. Error rows always record.
    def recordable? = error? || (paid_sales.present? && paid_sales >= MIN_PAID_SALES)
  end

  class << self
    # One bounded query per call: seller_id + purchase_state + created_at range, covered by
    # index_purchases_on_seller_id_and_purchase_state_and_created_at, capped at SAMPLE_LIMIT
    # rows. The free age clause runs first so the query is only paid for accounts young enough
    # to be candidates at all.
    def evaluate(seller:)
      if seller.created_at <= MAX_SELLER_AGE_DAYS.days.ago
        return Result.new(decision: DECISION_ALLOWED)
      end

      rows = Purchase.where(seller_id: seller.id, purchase_state: "successful")
                     .where("price_cents > 0")
                     .where(created_at: WINDOW.ago..)
                     .limit(SAMPLE_LIMIT)
                     .pluck(:card_country, :ip_address, :browser_guid)

      paid_sales = rows.size
      country_counts = rows.map(&:first).compact.tally
      dominant_card_country, dominant_count = country_counts.max_by { |_country, count| count }
      # nil card_country rows stay in the denominator, so unknowns always lower the share —
      # the conservative (allowing) direction.
      dominant_share_pct = paid_sales.zero? ? 0.0 : (100.0 * dominant_count.to_i / paid_sales).round(2)

      cidr_hits = Hash.new(0)
      rows.each do |_country, ip, _guid|
        cidr = matching_cidr(ip)
        cidr_hits[cidr] += 1 if cidr
      end
      hosting_count = cidr_hits.values.sum
      hosting_share_pct = paid_sales.zero? ? 0.0 : (100.0 * hosting_count / paid_sales).round(2)
      matched_cidr = cidr_hits.max_by { |_cidr, count| count }&.first

      distinct_browsers = rows.map(&:last).compact.uniq.size

      blocked = paid_sales >= MIN_PAID_SALES &&
        dominant_share_pct >= DOMINANT_CARD_COUNTRY_SHARE_PCT &&
        hosting_share_pct >= HOSTING_IP_SHARE_PCT

      Result.new(
        decision: blocked ? DECISION_BLOCKED : DECISION_ALLOWED,
        paid_sales:,
        dominant_card_country:,
        dominant_share_pct:,
        hosting_share_pct:,
        distinct_browsers:,
        matched_cidr:
      )
    end

    private
      def matching_cidr(ip)
        return nil if ip.blank?

        parsed = begin
          IPAddr.new(ip)
        rescue IPAddr::InvalidAddressError, ArgumentError
          # An unparseable stored IP counts as non-hosting: lowers the share, allows the sale.
          return nil
        end
        index = HOSTING_CIDRS.index { _1.include?(parsed) }
        index && HOSTING_CIDR_STRINGS[index]
      end
  end

  private
    # before_create, registered in Purchase right after check_for_fraud. Flag off => evaluate is
    # never called and nothing changes. On a hit the refusal is generic and names neither fraud
    # nor the seller; containment and telemetry run after commit (the refused purchase row still
    # persists — see the before_create comment in Purchase).
    def check_for_chargeback_ring_signal
      return if errors.present? # an earlier risk check already refused this purchase
      return if seller.nil?
      return if free_purchase?
      # Renewals aren't new ring sales, and blocking a young legitimate seller's renewals is the
      # worst false-positive shape — same carve-out as check_for_past_fraudulent_ips.
      return if is_recurring_subscription_charge
      return unless Feature.active?(Purchase::ChargebackRingSignal::FEATURE_FLAG, seller)

      @chargeback_ring_signal_result = Purchase::ChargebackRingSignal.evaluate(seller:)
      return unless @chargeback_ring_signal_result.hit?

      self.error_code = PurchaseErrorCode::CHARGEBACK_RING_SIGNAL
      # Generic, non-accusatory refusal — the same wording the sibling risk checks use.
      errors.add :base, vague_error_message
    rescue StandardError => e
      # Fail-open: never refuse a legitimate sale because this signal broke.
      @chargeback_ring_signal_result = Purchase::ChargebackRingSignal::Result.new(
        decision: Purchase::ChargebackRingSignal::DECISION_ERROR
      )
      ErrorNotifier.notify(e, seller_id: seller&.id)
      nil
    end

    # after_commit on: :create. Rescued wholesale: telemetry and containment must never surface
    # as a purchase failure — the refusal (if any) already happened in the before_create.
    def record_chargeback_ring_signal
      result = @chargeback_ring_signal_result
      return if result.nil?
      return unless result.recordable?

      ::ChargebackRingSignal.create!(
        seller_id:,
        purchase_id: id,
        decision: result.decision,
        paid_sales: result.paid_sales,
        dominant_card_country: result.dominant_card_country,
        dominant_share_pct: result.dominant_share_pct,
        hosting_share_pct: result.hosting_share_pct,
        distinct_browsers: result.distinct_browsers,
        matched_cidr: result.matched_cidr
      )

      if result.hit?
        pause_seller_payouts_for_ring_signal!(result)
        ErrorNotifier.notify(
          "chargeback_ring_signal blocked purchase: seller_id=#{seller_id} paid_sales=#{result.paid_sales} " \
          "dominant=#{result.dominant_card_country} #{result.dominant_share_pct}% " \
          "hosting=#{result.hosting_share_pct}% cidr=#{result.matched_cidr}"
        )
      end
    rescue StandardError => e
      ErrorNotifier.notify(e, purchase_id: id, seller_id:)
    end

    # Same pause mechanism as the existing chargeback-rate gate
    # (Purchase::Blockable#pause_payouts_for_seller_based_on_chargeback_rate!): the internal
    # system pause flag plus an on-probation comment, with the same outranking-source and
    # locked re-check discipline. The author is registered in
    # User::SYSTEM_PAYOUT_PAUSING_COMMENT_AUTHORS so the hold is attributed correctly — and
    # because it differs from high_chargeback_rate, ReleaseChargebackRatePayoutPausesJob never
    # auto-lifts it (a ring seller's measured chargeback rate is still LOW at block time; the
    # disputes haven't landed yet). Only an admin lifts this hold.
    # No suspension here — payout containment only; a human decides the account's fate.
    def pause_seller_payouts_for_ring_signal!(result)
      outranking_sources = [User::PAYOUT_PAUSE_SOURCE_ADMIN, User::PAYOUT_PAUSE_SOURCE_SYSTEM]
      return if outranking_sources.include?(seller.payouts_paused_by_source)

      seller.with_lock do
        next if outranking_sources.include?(seller.payouts_paused_by_source)

        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        seller.comments.create(
          content: "Payouts automatically paused by the checkout chargeback-ring signal: " \
            "#{result.paid_sales} paid sales in #{Purchase::ChargebackRingSignal::WINDOW.inspect}, " \
            "#{result.dominant_share_pct}% from #{result.dominant_card_country}, " \
            "#{result.hosting_share_pct}% from hosting block #{result.matched_cidr}, " \
            "#{result.distinct_browsers} distinct browsers.",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal]
        )
      end
    end
end
