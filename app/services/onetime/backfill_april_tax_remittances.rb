# frozen_string_literal: true

# Backfills the April 2026 international tax remittances (settling Q1 2026
# collections) into tax_remittances. These seven payments were made by hand
# from the Wise treasury dashboard and reconciled into QBO manually — this
# seeds the system of record (gumroad-private#1100) with its first real
# dataset so the read-only Wise sync and JE drafting have history to match
# against.
#
# USD amounts and payment dates come from the QBO general ledger (account
# 1049 "Wise Business x2956", April 2026 expense entries). Dates are the GL
# transaction dates, recorded as midnight UTC — the GL doesn't carry a
# time of day. The local-currency amounts aren't in QBO, so
# target_amount_cents stays nil; the Wise statement sync can fill them in
# later by matching transfer IDs.
#
# Idempotent: each historical payment is keyed on (authority, period,
# attempt: 1) — these were the first (and only) payment attempts for their
# filings — so re-running skips anything already present. The lookup pins
# attempt 1 explicitly: a row for a LATER attempt of the same filing must
# not be mistaken for the historical first payment.
class Onetime::BackfillAprilTaxRemittances
  PERIOD = "2026-Q1"

  # authority => [USD cents paid, GL transaction date], from the QBO GL
  # April 2026 entries against the Wise Business account.
  APRIL_2026_PAYMENTS = {
    "Irish Revenue (EU VAT OSS)" => [70_308_965, Time.utc(2026, 4, 17)],
    "HMRC" => [25_333_498, Time.utc(2026, 4, 28)],
    "Australian Taxation Office" => [8_135_407, Time.utc(2026, 4, 13)],
    "Norwegian Tax Administration" => [2_621_418, Time.utc(2026, 4, 13)],
    "Inland Revenue Department (NZ)" => [1_753_085, Time.utc(2026, 4, 30)],
    "Eidgenössisches Finanzdepartement (Swiss VAT)" => [1_699_222, Time.utc(2026, 4, 28)],
    "IRAS Singapore" => [953_288, Time.utc(2026, 4, 28)],
  }.freeze

  attr_reader :created, :skipped

  def initialize
    @created = []
    @skipped = []
  end

  def process
    APRIL_2026_PAYMENTS.each do |authority, (usd_cents, paid_at)|
      meta = TaxRemittance::KNOWN_AUTHORITIES.fetch(authority)

      # Pin attempt: 1 — the table allows multiple attempts per (authority,
      # period), and a row for attempt 2+ is NOT the historical first payment
      # we're backfilling. Without this, an unrelated later attempt would be
      # counted as "already backfilled" and the real attempt-1 row never written.
      existing = TaxRemittance.find_by(authority:, period: PERIOD, attempt: 1)
      if existing
        # A row already occupies this (authority, period, attempt 1) slot.
        # Only treat it as "already backfilled" when it actually matches the
        # historical payment we intend to record — a row with a different
        # amount, date, rail, or status would silently leave wrong data in the
        # system of record (the unique index blocks us from ever writing the
        # correct row).
        verify_existing_row!(existing, usd_cents, paid_at, meta)
        @skipped << authority
        next
      end

      # The historical row is written as `completed`, which counts as a live
      # attempt under the single-live-attempt-per-filing rule. If some later
      # attempt for this filing is already live (draft/pending_approval/
      # funded/sent/completed), inserting the backfill row would put two live
      # attempts on one filing — the exact double-payment shape the model
      # validation exists to block. Rather than letting create! abort the run
      # with an opaque RecordInvalid, detect it here and explain what needs
      # reconciling: a live later attempt existing while the historical first
      # payment is unrecorded means the table's history for this filing is
      # wrong and a human has to sort it out before re-running.
      live_later_attempt = TaxRemittance.where(authority:, period: PERIOD)
                                        .where.not(status: TaxRemittance::RETRYABLE_STATUSES)
                                        .first
      if live_later_attempt
        raise "BackfillAprilTaxRemittances: #{authority} #{PERIOD} has a live attempt #{live_later_attempt.attempt} " \
              "(status #{live_later_attempt.status}) but no attempt-1 row — backfilling the historical completed " \
              "payment would create two live attempts for one filing. Reconcile the filing's history manually before re-running"
      end

      begin
        TaxRemittance.create!(
          authority:,
          jurisdiction: meta[:jurisdiction],
          period: PERIOD,
          currency: meta[:currency],
          usd_amount_cents: usd_cents,
          rail: "wise",
          attempt: 1,
          status: "completed",
          paid_at:,
          notes: "Backfilled from QBO GL (manual Wise dashboard payment, April 2026). " \
                 "Local-currency amount and Wise transfer ID pending statement sync.",
        )
        @created << authority
      rescue ActiveRecord::RecordNotUnique
        # A concurrent run inserted this row between our find_by check and the
        # create!. The unique (authority, period, attempt) index makes that
        # harmless — verify the winner recorded the same payment, then count
        # it as skipped, same as if we had seen it up front.
        verify_existing_row!(TaxRemittance.find_by!(authority:, period: PERIOD, attempt: 1), usd_cents, paid_at, meta)
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
    def verify_existing_row!(existing, usd_cents, paid_at, meta)
      mismatches = {
        usd_amount_cents: [existing.usd_amount_cents, usd_cents],
        jurisdiction: [existing.jurisdiction, meta[:jurisdiction]],
        currency: [existing.currency, meta[:currency]],
        rail: [existing.rail, "wise"],
        status: [existing.status, "completed"],
        paid_at: [existing.paid_at, paid_at],
      }.select { |_field, (actual, expected)| actual != expected }

      return if mismatches.empty?

      details = mismatches.map { |field, (actual, expected)| "#{field}: has #{actual.inspect}, expected #{expected.inspect}" }
      raise "BackfillAprilTaxRemittances: existing #{existing.authority} #{PERIOD} row conflicts with backfill data (#{details.join('; ')}) — reconcile manually before re-running"
    end
end
