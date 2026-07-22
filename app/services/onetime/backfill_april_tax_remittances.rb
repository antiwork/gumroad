# frozen_string_literal: true

# Backfills the April 2026 international tax remittances (settling Q1 2026
# collections) into tax_remittances. These seven payments were made by hand
# from the Wise treasury dashboard and reconciled into QBO manually — this
# seeds the system of record (gumroad-private#1100) with its first real
# dataset so the read-only Wise sync and JE drafting have history to match
# against.
#
# USD amounts come from the QBO general ledger (account 1049 "Wise Business
# x2956"). The local-currency amounts aren't in QBO, so target_amount_cents
# stays nil; the Wise statement sync can fill them in later by matching
# transfer IDs.
#
# Idempotent: rows are keyed on (authority, period), so re-running skips
# anything already present.
class Onetime::BackfillAprilTaxRemittances
  PERIOD = "2026-Q1"
  PAID_ON = Time.utc(2026, 4, 15)

  # authority => USD cents paid, from the QBO GL April 2026 entries.
  APRIL_2026_PAYMENTS_USD_CENTS = {
    "Irish Revenue (EU VAT OSS)" => 70_308_965,
    "HMRC" => 25_333_498,
    "Australian Taxation Office" => 8_135_407,
    "Norwegian Tax Administration" => 2_621_418,
    "Inland Revenue Department (NZ)" => 1_753_085,
    "Eidgenössisches Finanzdepartement (Swiss VAT)" => 1_699_222,
    "IRAS Singapore" => 953_288,
  }.freeze

  attr_reader :created, :skipped

  def initialize
    @created = []
    @skipped = []
  end

  def process
    APRIL_2026_PAYMENTS_USD_CENTS.each do |authority, usd_cents|
      meta = TaxRemittance::KNOWN_AUTHORITIES.fetch(authority)

      existing = TaxRemittance.find_by(authority:, period: PERIOD)
      if existing
        # A row already occupies this (authority, period) slot. Only treat it
        # as "already backfilled" when it actually matches the historical
        # payment we intend to record — a row with a different amount, rail,
        # or status would silently leave wrong data in the system of record
        # (the unique index blocks us from ever writing the correct row).
        verify_existing_row!(existing, usd_cents, meta)
        @skipped << authority
        next
      end

      begin
        TaxRemittance.create!(
          authority:,
          jurisdiction: meta[:jurisdiction],
          period: PERIOD,
          currency: meta[:currency],
          usd_amount_cents: usd_cents,
          rail: "wise",
          status: "completed",
          paid_at: PAID_ON,
          notes: "Backfilled from QBO GL (manual Wise dashboard payment, April 2026). " \
                 "Local-currency amount and Wise transfer ID pending statement sync.",
        )
        @created << authority
      rescue ActiveRecord::RecordNotUnique
        # A concurrent run inserted this row between our find_by check and the
        # create!. The unique (authority, period) index makes that harmless —
        # verify the winner recorded the same payment, then count it as
        # skipped, same as if we had seen it up front.
        verify_existing_row!(TaxRemittance.find_by!(authority:, period: PERIOD), usd_cents, meta)
        @skipped << authority
      end
    end

    Rails.logger.info("BackfillAprilTaxRemittances: created=#{created.size} skipped=#{skipped.size}")
    self
  end

  private
    # Raises when the pre-existing row for this (authority, period) doesn't
    # match the historical payment being backfilled. Failing loudly is the
    # only safe option: the unique index means we can't insert the correct
    # row alongside it, and silently skipping would leave a wrong amount in
    # a table that finance automation treats as the source of truth.
    def verify_existing_row!(existing, usd_cents, meta)
      mismatches = {
        usd_amount_cents: [existing.usd_amount_cents, usd_cents],
        jurisdiction: [existing.jurisdiction, meta[:jurisdiction]],
        currency: [existing.currency, meta[:currency]],
        rail: [existing.rail, "wise"],
        status: [existing.status, "completed"],
      }.select { |_field, (actual, expected)| actual != expected }

      return if mismatches.empty?

      details = mismatches.map { |field, (actual, expected)| "#{field}: has #{actual.inspect}, expected #{expected.inspect}" }
      raise "BackfillAprilTaxRemittances: existing #{existing.authority} #{PERIOD} row conflicts with backfill data (#{details.join('; ')}) — reconcile manually before re-running"
    end
end
