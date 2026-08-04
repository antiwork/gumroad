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

  attr_reader :period, :matched, :ambiguous, :unmatched

  def initialize(period)
    raise ArgumentError, "period must look like 2026-Q1 (got #{period.inspect})" unless period.to_s.match?(TaxRemittance::PERIOD_FORMAT)

    @period = period
    @matched = []
    @ambiguous = []
    @unmatched = []
  end

  # transfers — an array of Wise transfer hashes from GET /v1/transfers, each
  # expected to have at least :status, :targetCurrency, :targetValue,
  # :sourceValue, :created, :id.
  #
  # enrich: — when true (the default), matched rows have their transfer_id
  # written via an audited update. When false, this only reports what WOULD
  # match — used for a dry-run report before anything is written.
  def process(transfers, enrich: true)
    @matched = []
    @ambiguous = []
    @unmatched = []

    candidates_for_period.each do |remittance|
      sent_transfers = transfers.select { |t| t[:status] == "outgoing_payment_sent" && t[:targetCurrency] == remittance.currency }
      matches = sent_transfers.select { |t| within_tolerance?(t, remittance) }

      case matches.size
      when 0
        @unmatched << remittance
      when 1
        transfer = matches.first
        enrich_transfer_id!(remittance, transfer) if enrich
        @matched << MatchResult.new(remittance:, transfer:)
      else
        @ambiguous << AmbiguousResult.new(remittance:, candidates: matches)
      end
    end

    Rails.logger.info(
      "#{self.class.name}: period=#{period} matched=#{matched.size} " \
      "ambiguous=#{ambiguous.size} unmatched=#{unmatched.size}"
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
      return false unless transfer[:created] && (transfer_time(transfer) - remittance.paid_at).abs <= DATE_WINDOW

      target_amount = remittance.target_amount_cents
      # No recorded target amount (the April backfill's rows): compare the
      # transfer's own USD-equivalent leg instead. sourceValue is the transfer's
      # funding currency amount; every remittance so far is funded in USD, so
      # this is directly comparable to usd_amount_cents.
      compare_cents = target_amount || remittance.usd_amount_cents
      transfer_cents = target_amount ? cents(transfer[:targetValue]) : cents(transfer[:sourceValue])

      (transfer_cents - compare_cents).abs <= AMOUNT_TOLERANCE_CENTS
    end

    def transfer_time(transfer)
      Time.zone.parse(transfer[:created].to_s)
    end

    def cents(major_units)
      (major_units.to_f * 100).round
    end

    def enrich_transfer_id!(remittance, transfer)
      remittance.update!(transfer_id: transfer[:id].to_s)
    end
end
