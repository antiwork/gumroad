# frozen_string_literal: true

# Backfill script to fix orphaned reviews from bundle purchases that were
# fully or partially refunded.
#
# Two categories of broken data:
# 1. Pre-PR #2460 (merged 2026-01-06): refunding a bundle never cascaded
#    refund flags to product purchases, so reviews were never removed.
#    Fix: set the missing flag via `update!` to trigger the after_save callback.
# 2. Post-PR #2460: `mark_product_purchases_as_refunded!` correctly set
#    `stripe_partially_refunded` on product purchases, but the review logic
#    did not check that flag, so reviews survived despite the flag being set.
#    Fix: explicitly delete the review and update stats since re-saving an
#    unchanged flag would not trigger callbacks.
#
# Usage:
#   Onetime::BackfillBundleRefundReviews.new(dry_run: true).process  # preview
#   Onetime::BackfillBundleRefundReviews.new(dry_run: false).process # execute
class Onetime::BackfillBundleRefundReviews < Onetime::Base
  def initialize(dry_run: true)
    @dry_run = dry_run
    @affected_count = 0
    @fixed_count = 0
    @skipped_count = 0
  end

  def process
    refunded_bundle_purchases.find_each do |bundle_purchase|
      is_partially_refunded = !bundle_purchase.stripe_refunded? && bundle_purchase.stripe_partially_refunded?

      bundle_purchase.product_purchases.each do |product_purchase|
        review = product_purchase.product_review

        if is_partially_refunded
          next if product_purchase.stripe_partially_refunded? && (review.nil? || review.deleted?)
        else
          next if product_purchase.stripe_refunded?
        end

        refund_type = is_partially_refunded ? "partial" : "full"

        if @dry_run
          Rails.logger.info(
            "[DRY RUN] Would fix purchase #{product_purchase.id} (#{refund_type} refund) " \
            "(bundle: #{bundle_purchase.id}, product: #{product_purchase.link.name}, " \
            "review: #{review&.id || 'none'}, review_alive: #{review&.alive?})"
          )
          @affected_count += 1
        else
          if is_partially_refunded && product_purchase.stripe_partially_refunded?
            product_purchase.link.update_review_stat_via_rating_change(review.rating, nil)
            review.mark_deleted!
          elsif is_partially_refunded
            product_purchase.update!(stripe_partially_refunded: true)
          else
            product_purchase.update!(stripe_refunded: true)
          end
          Rails.logger.info(
            "Fixed purchase #{product_purchase.id} (#{refund_type} refund) " \
            "(bundle: #{bundle_purchase.id}, product: #{product_purchase.link.name}, " \
            "review: #{review&.id || 'none'}, review_deleted: #{review&.reload&.deleted?})"
          )
          @fixed_count += 1
        end
      rescue StandardError => e
        Rails.logger.error("Failed to fix purchase #{product_purchase.id}: #{e.message}")
        @skipped_count += 1
      end

      ReplicaLagWatcher.watch
    end

    if @dry_run
      Rails.logger.info("[DRY RUN] Done. Would fix: #{@affected_count}, Skipped: #{@skipped_count}")
    else
      Rails.logger.info("Done. Fixed: #{@fixed_count}, Skipped: #{@skipped_count}")
    end
  end

  private
    def refunded_bundle_purchases
      Purchase
        .where(Purchase.is_bundle_purchase_condition)
        .where("purchases.stripe_refunded = true OR purchases.stripe_partially_refunded = true")
        .includes(product_purchases: [:product_review, :link])
    end
end
