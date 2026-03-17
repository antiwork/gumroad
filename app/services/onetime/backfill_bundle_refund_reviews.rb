# frozen_string_literal: true

# Backfill script to fix orphaned reviews from bundle purchases that were
# fully or partially refunded before PR #2460 (merged 2026-01-06) added
# `mark_product_purchases_as_refunded!`.
#
# Before that PR, refunding a bundle set `stripe_refunded` or
# `stripe_partially_refunded` on the bundle purchase but never cascaded
# to the individual product purchases. Reviews on those product purchases
# were never soft-deleted.
#
# Usage:
#   Onetime::BackfillBundleRefundReviews.new(dry_run: true).process  # preview
#   Onetime::BackfillBundleRefundReviews.new(dry_run: false).process # execute
class Onetime::BackfillBundleRefundReviews < Onetime::Base
  PR_2460_MERGE_DATE = Date.new(2026, 1, 6).freeze

  def initialize(dry_run: true)
    @dry_run = dry_run
    @fixed_count = 0
    @skipped_count = 0
  end

  def process
    refunded_bundle_purchases.find_each do |bundle_purchase|
      is_partially_refunded = !bundle_purchase.stripe_refunded? && bundle_purchase.stripe_partially_refunded?

      bundle_purchase.product_purchases.each do |product_purchase|
        next if is_partially_refunded && product_purchase.stripe_partially_refunded?
        next if !is_partially_refunded && product_purchase.stripe_refunded?

        review = product_purchase.product_review
        refund_type = is_partially_refunded ? "partial" : "full"

        if @dry_run
          Rails.logger.info(
            "[DRY RUN] Would fix purchase #{product_purchase.id} (#{refund_type} refund) " \
            "(bundle: #{bundle_purchase.id}, product: #{product_purchase.link.name}, " \
            "review: #{review&.id || 'none'}, review_alive: #{review&.alive?})"
          )
        else
          if is_partially_refunded
            product_purchase.update!(stripe_partially_refunded: true)
          else
            product_purchase.update!(stripe_refunded: true)
          end
          Rails.logger.info(
            "Fixed purchase #{product_purchase.id} (#{refund_type} refund) " \
            "(bundle: #{bundle_purchase.id}, product: #{product_purchase.link.name}, " \
            "review: #{review&.id || 'none'}, review_deleted: #{review&.reload&.deleted?})"
          )
        end
        @fixed_count += 1
      rescue StandardError => e
        Rails.logger.error("Failed to fix purchase #{product_purchase.id}: #{e.message}")
        @skipped_count += 1
      end

      ReplicaLagWatcher.watch
    end

    Rails.logger.info("#{@dry_run ? '[DRY RUN] ' : ''}Done. Fixed: #{@fixed_count}, Skipped: #{@skipped_count}")
  end

  private
    def refunded_bundle_purchases
      Purchase
        .where(Purchase.is_bundle_purchase_condition)
        .where("purchases.stripe_refunded = true OR purchases.stripe_partially_refunded = true")
        .where("purchases.created_at < ?", PR_2460_MERGE_DATE)
        .includes(product_purchases: [:product_review, :link])
    end
end
