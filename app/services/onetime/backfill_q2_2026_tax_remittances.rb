# frozen_string_literal: true

# Backfills the Q2 2026 international tax remittances into tax_remittances.
# Unlike the April 2026 backfill (Onetime::BackfillAprilTaxRemittances), which
# sourced amounts from the QBO GL because the bank feed had booked them, these
# six payments were read directly from the Wise API (gumroad-private#1100,
# 2026-08-03) — the QBO feed for July never booked them at all (a separate
# reconciliation gap, gumroad-private#1181). Local-currency amounts are known
# here because they come from the rail, not the ledger, so target_amount_cents
# is populated — the April backfill couldn't do that.
#
# Switzerland is deliberately excluded: its Q2 filing was paid on 2026-08-04
# via API (Phase 4, `attempt: 1`, status `funded`) and already has a row.
# Backfilling it here would collide with that row under the (authority,
# period, attempt) unique index — correctly, since it is not a second payment.
#
# IRAS Singapore is backfilled at only ONE of the two Q2 sends recorded on the
# rail. The second (SGD 12,154.00, identical reference, 2026-07-31) matches
# the exact Q1 SGD amount, which is the signature of an accidental resend
# rather than a second liability — but intent can't be confirmed from the
# rail alone, and inserting it as a genuine attempt-2 payment would assert a
# double remittance that may not be real. That $9,458.73 stays unrecorded
# pending the human disposition already asked for on the issue.
#
# transfer_id is left nil, same as the April backfill: it is ENRICHABLE_WHEN_LOCKED,
# meaning it can move from nil to a value exactly once and is then frozen. Writing
# the Wise reference string here now would burn that one enrichment and permanently
# block the eventual Phase 3 sync from filling in the real numeric transfer ID it
# matches from the rail. The reference lives in notes instead, purely informational.
#
# Idempotent like the April backfill: keyed on (authority, period, attempt: 1),
# verified rather than silently skipped if a mismatched row already occupies
# that slot.
class Onetime::BackfillQ22026TaxRemittances
  PERIOD = "2026-Q2"

  # authority => [usd_cents, target_amount_cents, paid_at, transfer_reference]
  # USD/local amounts and dates are the Wise transfer records read on
  # 2026-08-03 (gumroad-private#1100 comment 5167307502). transfer_reference
  # is the payment reference Wise recorded, not a raw numeric transfer ID —
  # the rail sync (Phase 3, not yet built) can replace it with the real
  # transfer ID once it exists, since ENRICHABLE_WHEN_LOCKED allows that.
  Q2_2026_PAYMENTS = {
    "Irish Revenue (EU VAT OSS)" => [64_359_570, 56_393_915, Time.utc(2026, 7, 22), "EU372030009.Q2.2026"],
    "HMRC" => [24_456_761, 18_284_755, Time.utc(2026, 7, 22), "GB400134960 2Q2026"],
    "Australian Taxation Office" => [7_614_969, 10_882_400, Time.utc(2026, 7, 22), "811011766943121720"],
    "Norwegian Tax Administration" => [2_094_888, 20_207_900, Time.utc(2026, 7, 18), "2082039-Q2-2026"],
    "Inland Revenue Department (NZ)" => [1_592_102, 2_737_221, Time.utc(2026, 7, 22), "147042426"],
    "IRAS Singapore" => [1_023_136, 1_314_679, Time.utc(2026, 7, 31), "GST M90375350L Q2 2026"],
  }.freeze

  attr_reader :created, :skipped

  def initialize
    @created = []
    @skipped = []
  end

  def process
    Q2_2026_PAYMENTS.each do |authority, (usd_cents, target_cents, paid_at, reference)|
      meta = TaxRemittance::KNOWN_AUTHORITIES.fetch(authority)

      existing = TaxRemittance.find_by(authority:, period: PERIOD, attempt: 1)
      if existing
        verify_existing_row!(existing, usd_cents, target_cents, paid_at, meta)
        @skipped << authority
        next
      end

      live_later_attempt = TaxRemittance.where(authority:, period: PERIOD)
                                        .where.not(status: TaxRemittance::RETRYABLE_STATUSES)
                                        .first
      if live_later_attempt
        raise "BackfillQ22026TaxRemittances: #{authority} #{PERIOD} has a live attempt #{live_later_attempt.attempt} " \
              "(status #{live_later_attempt.status}) but no attempt-1 row — backfilling the rail-confirmed payment " \
              "would create two live attempts for one filing. Reconcile the filing's history manually before re-running"
      end

      begin
        TaxRemittance.create!(
          authority:,
          jurisdiction: meta[:jurisdiction],
          period: PERIOD,
          currency: meta[:currency],
          usd_amount_cents: usd_cents,
          target_amount_cents: target_cents,
          rail: "wise",
          attempt: 1,
          status: "completed",
          paid_at:,
          notes: "Backfilled from the Wise API (rail read 2026-08-03, gumroad-private#1100). " \
                 "Wise payment reference: #{reference}. Numeric transfer_id pending the Phase 3 rail sync.",
        )
        @created << authority
      rescue ActiveRecord::RecordNotUnique
        verify_existing_row!(
          TaxRemittance.find_by!(authority:, period: PERIOD, attempt: 1),
          usd_cents, target_cents, paid_at, meta
        )
        @skipped << authority
      end
    end

    Rails.logger.info("BackfillQ22026TaxRemittances: created=#{created.size} skipped=#{skipped.size}")
    self
  end

  private
    # Doesn't check transfer_id — it's deliberately left nil at insert (see the
    # comment above) so a later Phase 3 sync can still enrich it. notes isn't
    # checked either; it's an annotation, not a payment fact.
    def verify_existing_row!(existing, usd_cents, target_cents, paid_at, meta)
      mismatches = {
        usd_amount_cents: [existing.usd_amount_cents, usd_cents],
        target_amount_cents: [existing.target_amount_cents, target_cents],
        jurisdiction: [existing.jurisdiction, meta[:jurisdiction]],
        currency: [existing.currency, meta[:currency]],
        rail: [existing.rail, "wise"],
        status: [existing.status, "completed"],
        paid_at: [existing.paid_at, paid_at],
      }.select { |_field, (actual, expected)| actual != expected }

      return if mismatches.empty?

      details = mismatches.map { |field, (actual, expected)| "#{field}: has #{actual.inspect}, expected #{expected.inspect}" }
      raise "BackfillQ22026TaxRemittances: existing #{existing.authority} #{PERIOD} row conflicts with backfill data (#{details.join('; ')}) — reconcile manually before re-running"
    end
end
