# frozen_string_literal: true

class CreateTaxRemittances < ActiveRecord::Migration[7.1]
  def change
    create_table :tax_remittances do |t|
      # Who we paid: the tax authority's display name (e.g. "HMRC") and the
      # jurisdiction it collects for (ISO country code, or "EU_OSS" for the
      # Irish Revenue one-stop-shop filing that covers all EU member states).
      t.string :authority, null: false
      t.string :jurisdiction, null: false

      # The filing period the payment settles, as "YYYY-QN" (e.g. "2026-Q1").
      # Remittances are quarterly today; a string keeps room for monthly
      # filings if a jurisdiction ever requires them.
      t.string :period, null: false

      # Amount actually remitted, in the authority's currency (e.g. GBP for
      # HMRC), plus the USD cost booked in QBO. target_amount_cents is
      # nullable because historical backfills from the QBO general ledger
      # only know the USD side; API-synced rows always have both.
      t.string :currency, null: false, limit: 3
      t.bigint :target_amount_cents
      t.bigint :usd_amount_cents, null: false

      # Which payment rail moved the money. Wise is the default; Stripe
      # Global Payouts is the fallback for authorities Wise can't pay, and
      # Mercury covers anything paid directly from checking.
      t.string :rail, null: false, default: "wise"

      # The rail-side identifier (Wise transfer ID, Stripe payout ID, or
      # Mercury transaction ID) once the payment exists on the rail.
      t.string :transfer_id

      t.string :status, null: false, default: "draft"

      # Payment attempts for one (authority, period) filing are numbered from
      # 1. A failed or cancelled attempt stays in the table as history, and a
      # retry inserts a fresh row with the next attempt number — the model
      # guarantees at most one attempt per filing is ever "live"
      # (not failed/cancelled).
      t.integer :attempt, null: false, default: 1

      t.datetime :paid_at

      # Reference to the QuickBooks journal entry that books the 4-way split
      # (2410 collected tax / 6730 Wise fee / 7025 FX gain-loss / 1049 cash).
      t.string :qbo_journal_entry_ref

      t.text :notes

      t.timestamps

      t.index [:authority, :period, :attempt], unique: true
      # Unique so one rail-side payment can never be reconciled against two
      # remittance rows (which would double-count real money). MySQL unique
      # indexes allow multiple NULLs, so rows awaiting a transfer ID coexist.
      t.index [:rail, :transfer_id], unique: true
      t.index [:status, :period]
    end
  end
end
