# frozen_string_literal: true

# Pre-charge signal for card-testing cash-out rings: the daily chargeback-ring scan could only
# pause payouts after a ring's sales had already been charged.
#
# The country-dominance and hosting-IP clauses only mean anything together: young legitimate
# sellers whose buyers share one country are common, and a datacenter block is what separates a
# mill from them. All four clauses below must hold to block.
#
# Flag off means evaluate is never called, so there is zero behaviour change until it is enabled.
# Fail-open: an exception allows the purchase and records an `error` row. Every evaluation at or
# above MIN_PAID_SALES writes a row (blocked or allowed) so precision is measurable in SQL.
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
    # The age clause is decided before any query, so the bounded sample below is only ever read
    # for accounts young enough to be candidates.
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
    # before_create in Purchase, registered right after check_for_fraud. Containment and telemetry
    # run after commit — the refused purchase row still persists (see the before_create comment in
    # Purchase). The refusal message names neither fraud nor the seller.
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
    # system pause flag plus an on-probation comment, with the same locked re-check discipline.
    #
    # The comment landing LAST is what makes the containment hold: User#payouts_paused_for_chargeback_rate?
    # reads the newest pausing comment, and a ring seller's rate is still low when the signal fires,
    # so a hold that still reads as the chargeback-rate one would be auto-released by
    # ReleaseChargebackRatePayoutPausesJob and would pay the 75% reserve until then. An existing
    # automatic hold therefore must not short-circuit this — only a human's own pause is left
    # untouched. (A Stripe-source pause is not preserved either: UpdatePayoutMethod clears that
    # source on a payout-method change, which would release the balance to the disputes in flight.)
    # No suspension here: payout containment only, a human decides the account's fate.
    def pause_seller_payouts_for_ring_signal!(result)
      preserved_sources = [User::PAYOUT_PAUSE_SOURCE_ADMIN]
      return if preserved_sources.include?(seller.payouts_paused_by_source)

      seller.with_lock do
        next if preserved_sources.include?(seller.payouts_paused_by_source)
        # A second blocked sale must not append another comment once the ring's own is the newest.
        next if seller.payouts_paused_for_chargeback_ring_signal?

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
