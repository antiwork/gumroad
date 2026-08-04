# frozen_string_literal: true

# Matches Wise transfer history against `tax_remittances` rows that already
# have a recorded payment (paid_at set) but no `transfer_id` — the rows
# written by the April and Q2 2026 backfills, which sourced amounts from the
# QBO GL or a manual Wise API read rather than from a live transfer object.
#
# Deliberately narrow (gumroad-private#1100 Phase 3): this is a matcher, not a
# sync job. It takes a caller-supplied list of Wise transfer hashes (the exact
# shape GET /v1/transfers?profile=... returns) rather than calling the Wise
# API itself, so it has no credential dependency and is fully testable with
# fixtures. Wiring it to a live client and a recurring schedule is a separate
# decision, not made here.
#
# Matching is amount + currency + a date window around the recorded paid_at,
# never a reference-string match: the seven authorities' Wise references have
# no shared format (compare "EU372030009.Q2.2026" to "811011766943121720"),
# so amount is the only signal that generalizes across all of them. This is
# why a transfer is only ever a CANDIDATE until reviewed — an FX-rounding
# collision at the cent is possible in principle, even if none has been
# observed. Enrichment is refused whenever more than one candidate ties on
# amount, rather than guessing.
class TaxRemittances::WiseTransferMatcher
  # Registers a transfer's targetValue against a remittance's target_amount_cents
  # (both are the local-currency amount actually sent) within one cent of
  # rounding, since the two sides are computed on different scales (integer
  # cents here, a float major-unit amount from Wise).
  AMOUNT_TOLERANCE_CENTS = 1
  # How far the transfer's `created` timestamp may sit from paid_at. Payments
  # are typically dated same-day, but Wise's cancel/resend pattern (seen on
  # every quarter so far) and weekend settlement can push a transfer's
  # `created` a few days from the paid_at we recorded. Wide enough to catch
  # that, narrow enough that a same-currency, same-amount transfer from a
  # different quarter's filing can't be mistaken for this one.
  DATE_WINDOW = 5.days

  MatchResult = Struct.new(:remittance, :transfer, keyword_init: true)
  AmbiguousResult = Struct.new(:remittance, :candidates, keyword_init: true)

  attr_reader :period, :matched, :ambiguous, :unmatched, :unclaimed_transfers

  def initialize(period)
    raise ArgumentError, "period must look like 2026-Q1 (got #{period.inspect})" unless period.to_s.match?(TaxRemittance::PERIOD_FORMAT)

    @period = period
    @matched = []
    @ambiguous = []
    @unmatched = []
    @unclaimed_transfers = []
  end

  # transfers — an array of Wise transfer hashes from GET /v1/transfers, each
  # expected to have at least :status, :targetCurrency, :targetValue,
  # :sourceCurrency, :sourceValue, :created, :id.
  #
  # enrich: — when true (the default), matched rows have their transfer_id
  # written via an audited update. When false, this only reports what WOULD
  # match — used for a dry-run report before anything is written.
  def process(transfers, enrich: true)
    # JSON.parse gives String keys; the matcher reads Symbols throughout.
    transfers = transfers.map { |t| t.to_h.symbolize_keys }
    @matched = []
    @ambiguous = []
    @unmatched = []

    sent_transfers = transfers.select { |t| t[:status] == "outgoing_payment_sent" }
    # Any sent transfer that was never even a candidate for a remittance
    # (id never lands in `claimed_ids`) would otherwise vanish silently —
    # it isn't matched, ambiguous, or unmatched (those buckets are keyed by
    # remittance, not by transfer), so nothing on the rail with no matching
    # row goes unreported without tracking this separately.
    claimed_ids = Set.new

    # Two passes: a remittance with exactly one candidate here can still be
    # contested by a SIBLING remittance that also uniquely lands on the same
    # transfer (same currency/amount/window, e.g. two authorities paid the
    # same amount the same week). Tally claims per transfer id first, then
    # resolve — a transfer claimed by more than one remittance goes to
    # ambiguous for all of them instead of being written to whichever
    # remittance happened to be iterated first.
    tentative = candidates_for_period.filter_map do |remittance|
      currency_transfers = sent_transfers.select { |t| t[:targetCurrency] == remittance.currency }
      matches = currency_transfers.select { |t| within_tolerance?(t, remittance) }
      matches.each { |t| claimed_ids << t[:id] }

      case matches.size
      when 0
        @unmatched << remittance
        nil
      when 1
        [remittance, matches.first]
      else
        @ambiguous << AmbiguousResult.new(remittance:, candidates: matches)
        nil
      end
    end

    claims = tentative.group_by { |(_, transfer)| transfer[:id] }

    claims.each_value do |claimants|
      if claimants.size == 1
        remittance, transfer = claimants.first
        enrich_transfer_id!(remittance, transfer) if enrich
        @matched << MatchResult.new(remittance:, transfer:)
      else
        claimants.each do |remittance, transfer|
          @ambiguous << AmbiguousResult.new(remittance:, candidates: [transfer])
        end
      end
    end

    @unclaimed_transfers = sent_transfers.reject { |t| claimed_ids.include?(t[:id]) }

    Rails.logger.info(
      "#{self.class.name}: period=#{period} matched=#{matched.size} " \
      "ambiguous=#{ambiguous.size} unmatched=#{unmatched.size} " \
      "unclaimed_transfers=#{unclaimed_transfers.size}"
    )

    self
  end

  private
    # Only rows with a real payment recorded but no transfer_id yet — anything
    # else either hasn't been paid (nothing to match against the rail) or is
    # already reconciled.
    def candidates_for_period
      TaxRemittance.for_period(period)
                   .where(rail: "wise", transfer_id: nil)
                   .where.not(paid_at: nil)
    end

    def within_tolerance?(transfer, remittance)
      # Malformed `created` values parse to nil; treat them as nonmatching so one
      # bad transfer surfaces in unclaimed_transfers instead of aborting the batch.
      time = transfer_time(transfer)
      return false unless time && (time - remittance.paid_at).abs <= DATE_WINDOW

      target_amount = remittance.target_amount_cents
      # No recorded target amount (the April backfill's rows): compare the
      # transfer's own USD-equivalent leg instead. sourceValue is the transfer's
      # funding currency amount, so it is only comparable to usd_amount_cents
      # when the transfer was actually funded in USD — a EUR-funded transfer can
      # collide numerically with a USD figure and would be written as a match.
      if target_amount
        (cents(transfer[:targetValue]) - target_amount).abs <= AMOUNT_TOLERANCE_CENTS
      else
        return false unless transfer[:sourceCurrency].to_s.upcase == "USD"

        (cents(transfer[:sourceValue]) - remittance.usd_amount_cents).abs <= AMOUNT_TOLERANCE_CENTS
      end
    end

    def transfer_time(transfer)
      Time.zone.parse(transfer[:created].to_s)
    rescue ArgumentError
      nil
    end

    def cents(major_units)
      (major_units.to_f * 100).round
    end

    def enrich_transfer_id!(remittance, transfer)
      remittance.update!(transfer_id: transfer[:id].to_s)
    end
end
