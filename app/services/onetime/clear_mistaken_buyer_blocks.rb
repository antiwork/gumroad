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
# Run it from a console. It reports without changing anything unless you ask it to clear:
#
#   Onetime::ClearMistakenBuyerBlocks.new.process                    # report only
#   Onetime::ClearMistakenBuyerBlocks.new(dry_run: false).process     # clear them
#
# It only touches a PlatformBlock row when all of these hold, which together fingerprint the rows
# this specific bug created:
#
#   * the row was created by automation, not by a person (blocked_by is nil), so a deliberate admin
#     block and the chargeback auto-block (which records GUMROAD_ADMIN_ID) are never touched;
#   * its type and value match one of the values the old rule wrote for a particular failed
#     purchase, matched as a (type, value) pair — matching on value alone would let an
#     email-shaped value under one type clear a row of another;
#   * it was created in the same moment that purchase failed, since the old rule ran inside the
#     failure transition. A purchase does not always fail when it is created — one needing Strong
#     Customer Authentication can fail up to fifteen minutes later — so the search covers that
#     whole span and then keeps only the rows written within a couple of minutes of the earliest
#     one, which is how the old rule's single burst of inserts looks. This is what keeps the sweep
#     away from the card-testing velocity blocks, which write identical rows from a different code
#     path at a different time, and away from an IP address that was blocked because of somebody
#     else entirely;
#   * the failed purchase's decline code is one of the fraud-related ones;
#   * and the buyer's payment history is clean by the same standard the live code now uses.
class Onetime::ClearMistakenBuyerBlocks
  # How far back to look for the decline that caused the block.
  DEFAULT_LOOKBACK = 1.year

  # How wide a window around the moment of failure counts as "written by that failure". The old
  # rule created every row synchronously in the state transition, so this only has to cover the
  # handful of inserts plus clock skew between the app and the database.
  BLOCK_CREATION_WINDOW = 2.minutes

  def initialize(dry_run: true, lookback: DEFAULT_LOOKBACK)
    @dry_run = dry_run
    @lookback = lookback
  end

  # Returns one row per buyer we cleared (or, in a dry run, would clear), each listing the blocks
  # involved, so the run can be pasted into the issue as a record of what changed.
  def process
    cleared = []

    candidate_purchases.find_each do |purchase|
      blocks = mistaken_blocks_for(purchase)
      next if blocks.empty?
      next unless purchase.buyer_has_clean_payment_history?

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

    # The active, automation-created blocks that this purchase's failure wrote. Mirrors exactly what
    # the old Purchase::Blockable#block_buyer! blocked, as (type, value) pairs.
    #
    # Matching on time is what keeps this sweep away from the card-testing velocity blocks, which
    # write identical-looking rows from a different code path, and away from an IP address that was
    # blocked because of somebody else entirely. Two facts make that harder than it looks:
    #
    #   * purchases carry no failed_at, and a purchase does not necessarily fail the moment it is
    #     created. A charge needing Strong Customer Authentication sits in progress until the buyer
    #     finishes (or FailAbandonedPurchaseWorker gives up ChargeProcessor::TIME_TO_COMPLETE_SCA
    #     later), and the blocks were written in that later transition. A window centred on
    #     created_at misses those rows entirely and leaves the buyer blocked after a sweep that
    #     reported them cleared.
    #   * simply widening the window to cover the whole SCA period would let a row written minutes
    #     apart, by another code path, look like part of this failure.
    #
    # So: look in the outer bound of when the failure could have happened, then require that the
    # rows we clear are tight around the earliest of them. The old rule wrote all of its rows in one
    # synchronous transition, so genuine rows sit within seconds of each other; a velocity block
    # from a separate event minutes away falls outside that inner window and is left alone.
    def mistaken_blocks_for(purchase)
      pairs = blocked_pairs_for(purchase)
      return [] if pairs.empty?

      candidates = PlatformBlock.active
                                .where(blocked_by: nil, created_at: possible_failure_window(purchase))
                                .where(pairs.map { "(object_type = ? AND object_value = ?)" }.join(" OR "), *pairs.flatten)
                                .to_a
      return [] if candidates.empty?

      earliest = candidates.map(&:created_at).min
      candidates.select { |block| block.created_at <= earliest + BLOCK_CREATION_WINDOW }
    end

    # When the failure that wrote the blocks could have happened: at creation at the earliest, and
    # at the SCA deadline at the latest, plus the window for clock skew on either side.
    def possible_failure_window(purchase)
      (purchase.created_at - BLOCK_CREATION_WINDOW)..
        (purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA + BLOCK_CREATION_WINDOW)
    end

    def blocked_pairs_for(purchase)
      emails = [purchase.email, purchase.paypal_email, purchase.gifter_email, purchase.purchaser_email]
      fingerprints = [purchase.charge_processor_fingerprint, historical_recent_stripe_fingerprint(purchase)]

      pairs = emails.compact_blank.uniq.map { [PlatformBlock::TYPES[:email], _1] }
      pairs += fingerprints.compact_blank.uniq.map { [PlatformBlock::TYPES[:charge_processor_fingerprint], _1] }
      pairs << [PlatformBlock::TYPES[:browser_guid], purchase.browser_guid] if purchase.browser_guid.present?
      pairs << [PlatformBlock::TYPES[:ip_address], purchase.ip_address] if purchase.ip_address.present?
      pairs
    end

    # The card that Purchase::Blockable#recent_stripe_fingerprint would have returned back when the
    # block was created — "the buyer's most recent card" as of that moment, not as of today.
    #
    # Calling the live method here would return whatever card the buyer has used since, so a buyer
    # who moved on to a new card after being blocked would have that new card's fingerprint checked
    # (it was never blocked) while the row the old rule actually wrote went unnoticed. The buyer
    # stays unable to pay with the older card while the run reports them cleared. Reconstructing it
    # by bounding on the purchase's own id reproduces the original ordering exactly, since the
    # original called .last on the same set and no row with a higher id existed yet.
    def historical_recent_stripe_fingerprint(purchase)
      Purchase.with_stripe_fingerprint
              .where("purchaser_id = ? or email = ?", purchase.purchaser_id, purchase.email)
              .where(id: ..purchase.id)
              .last&.stripe_fingerprint
    end
end
