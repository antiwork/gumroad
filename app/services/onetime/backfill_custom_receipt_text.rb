# frozen_string_literal: true

# Restores custom receipt text that silently disappeared from buyer receipts for products last
# edited before the customizable-receipts feature shipped (December 2025, #2180).
#
# Before that change, the receipt email read the seller's custom text from the legacy
# `links.custom_receipt` column. The feature moved the read to a new `custom_receipt_text`
# attribute stored in `links.json_data`, but shipped without copying the old column into the new
# field. Products whose sellers wrote receipt text before the change — and haven't re-saved it in
# the new Receipt tab since — send receipts without that text, even though the legacy column still
# holds it.
#
# This copies non-blank `links.custom_receipt` into `json_data.custom_receipt_text` wherever the
# new field is still blank, restoring the seller's original wording on future receipts and resends.
#
# Notes on scope and safety:
#   * Deleted products are included: buyers can still request receipt resends for purchases of
#     deleted products, and those receipts render from the product record.
#   * Products where the new field is already set are skipped — the seller (or an earlier manual
#     restore) has already chosen the new-format text, and this task must never overwrite it. The
#     check is re-done under a row lock right before the write, so a seller saving receipt text
#     while the task is running can't be overwritten by a stale copy of the row. One known
#     trade-off: a seller who set text in the new Receipt tab and later cleared it (leaving an
#     empty string in json_data) is indistinguishable from never-migrated, so their legacy wording
#     is restored. A key-presence check would be wrong the other way — the product editor
#     round-trips the field on every save — so value-presence is the deliberate choice.
#   * Legacy text longer than the new field's validation limit
#     (Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH) is skipped and counted rather than
#     truncated or written as-is. Writing an over-limit value would make every subsequent save of
#     that product fail validation, breaking the seller's product editor; truncating would silently
#     rewrite wording the seller chose carefully. Those products are reported in the stats for a
#     human decision.
#   * Writes use update_column so the restore doesn't trigger the product's save callbacks
#     (search reindexing, cache busting, etc.) for a receipt-text-only data fix, and doesn't
#     require the rest of the (possibly old, otherwise-invalid) record to pass validation.
#   * This restores existing data only. The public API v2 still accepts writes to the legacy
#     `custom_receipt` param (which nothing reads anymore) — pointing that at the new field is
#     tracked separately on the regression issue and deliberately out of scope here.
#
# Idempotent and dry-run by default:
#
#   Onetime::BackfillCustomReceiptText.process                 # dry run, logs what it would do
#   Onetime::BackfillCustomReceiptText.process(dry_run: false) # writes
module Onetime
  class BackfillCustomReceiptText
    BATCH_SIZE = 1_000

    def self.process(dry_run: true, batch_size: BATCH_SIZE)
      new(dry_run:, batch_size:).process
    end

    def initialize(dry_run: true, batch_size: BATCH_SIZE)
      @dry_run = dry_run
      @batch_size = batch_size
      @stats = Hash.new(0)
    end

    def process
      Link.where.not(custom_receipt: [nil, ""]).find_each(batch_size: @batch_size) do |link|
        ReplicaLagWatcher.watch
        backfill(link)
      rescue => e
        @stats[:errors] += 1
        Rails.logger.error("[BackfillCustomReceiptText] link=#{link.id} error=#{e.class}: #{e.message}")
      end

      @stats[:dry_run] = @dry_run
      Rails.logger.info("[BackfillCustomReceiptText] #{@stats.to_h}")
      @stats
    end

    private
      def backfill(link)
        legacy_text = link.custom_receipt
        return tick(:skipped_blank_legacy) if legacy_text.blank?
        return tick(:skipped_already_set) if link.custom_receipt_text.present?

        if legacy_text.length > Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH
          Rails.logger.warn("[BackfillCustomReceiptText] link=#{link.id} legacy text is #{legacy_text.length} chars (limit #{Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH}), skipping — needs a human decision")
          return tick(:skipped_too_long)
        end

        return tick(:would_backfill) if @dry_run

        # Re-check the no-overwrite guard under a row lock before writing. The write below replaces
        # the whole json_data hash, so if a seller saved new receipt text between this row being
        # loaded and this write, an unguarded write would restore the stale hash and erase their
        # text. with_lock reloads the row with FOR UPDATE, so the seller's concurrent save either
        # lands before the re-check (and we skip) or waits until this transaction commits.
        outcome = link.with_lock do
          if link.custom_receipt_text.present?
            :skipped_already_set
          else
            # Copy into json_data without callbacks/validations (see class comment). The json_data
            # reader instantiates and mutates the in-memory hash, so write the merged hash back
            # through update_column, which serializes it via the model's JSON coder.
            link.set_json_data_for_attr("custom_receipt_text", legacy_text)
            link.update_column(:json_data, link.json_data)
            :backfilled
          end
        end
        tick(outcome)
      end

      def tick(key)
        @stats[key] += 1
      end
  end
end
