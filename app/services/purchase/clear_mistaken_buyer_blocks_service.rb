# frozen_string_literal: true

# One-off cleanup for the buyers that Purchase::Blockable#ban_buyer_on_fraud_related_error_code!
# platform-blocked before it learned to check payment history (gumroad-private#1480).
#
# The old rule blocked a buyer's browser, every email address on the purchase, their IP address and
# their card the first time an issuer declined a charge with a fraud-flavoured code — including
# "lost card" and "pickup card", which issuers hand out for ordinary card reissues. Long-standing
# customers were left unable to pay us with any card or through PayPal, with nothing on screen that
# explained why, and at least one membership lapsed because of it. The code no longer creates those
# blocks; the ones already in the database still have to be cleared, and nothing expires them
# (only the IP row has an expiry at all).
#
# Run it from a console:
#
#   Purchase::ClearMistakenBuyerBlocksService.new(dry_run: true).process   # report only
#   Purchase::ClearMistakenBuyerBlocksService.new.process                  # clear them
#
# It reports, and only clears, blocks that satisfy all of:
#   * they were created by automation, not by a person (blocked_by is nil), so a deliberate
#     admin block is never touched;
#   * they trace back to a failed purchase whose decline code is one of the fraud-related ones,
#     so card-testing velocity blocks — which are working as intended — are left alone;
#   * the buyer's payment history is clean by the same standard the live code now uses.
class Purchase::ClearMistakenBuyerBlocksService
  # How far back to look for the decline that caused the block. Blocks created by this path are
  # made at the moment the purchase fails, so a generous window over failed purchases finds them.
  DEFAULT_LOOKBACK = 1.year

  def initialize(dry_run: false, lookback: DEFAULT_LOOKBACK)
    @dry_run = dry_run
    @lookback = lookback
  end

  # Returns one row per buyer we cleared (or would clear in a dry run), each listing the block
  # values involved, so the run can be pasted into the issue as a record of what changed.
  def process
    cleared = []

    candidate_purchases.find_each do |purchase|
      blocks = automated_blocks_for(purchase)
      next if blocks.empty?
      next unless purchase.send(:buyer_has_clean_payment_history?)

      blocks.each(&:unblock!) unless dry_run
      cleared << {
        purchase_id: purchase.id,
        error_code: purchase.stripe_error_code || purchase.error_code,
        blocks: blocks.map { |block| [block.object_type, block.object_value] }
      }
    end

    cleared
  end

  private
    attr_reader :dry_run, :lookback

    def candidate_purchases
      Purchase.failed
              .where(created_at: lookback.ago..)
              .where(
                "stripe_error_code IN (:codes) OR error_code IN (:codes)",
                codes: PurchaseErrorCode::FRAUD_RELATED_ERROR_CODES
              )
    end

    # The active, automation-created blocks that hold this specific buyer. Mirrors the set of
    # values the old block wrote, so nothing else a buyer happens to share gets cleared.
    def automated_blocks_for(purchase)
      values = [
        purchase.browser_guid,
        purchase.ip_address,
        purchase.email,
        purchase.paypal_email,
        purchase.purchaser_email,
        purchase.charge_processor_fingerprint
      ].compact_blank.uniq

      return [] if values.empty?

      PlatformBlock.active.where(object_value: values, blocked_by: nil).to_a
    end
end
