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
#     away from a velocity block written minutes later by a different code path, and away from an
#     IP address that was blocked because of somebody else entirely;
#   * no card-testing velocity rule would have written the same row in that same transition. A
#     block row is unique per type and value, so one row can be both the mistaken block and a
#     deliberate velocity block; clearing it would quietly switch velocity enforcement off for
#     that identifier. See #velocity_protected_pairs;
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
      pairs = blocked_pairs_for(purchase) - velocity_protected_pairs(purchase)
      return [] if pairs.empty?

      candidates = PlatformBlock.active
                                .where(blocked_by: nil, created_at: possible_failure_window(purchase))
                                .where(pairs.map { "(object_type = ? AND object_value = ?)" }.join(" OR "), *pairs.flatten)
                                .to_a
      return [] if candidates.empty?

      earliest = candidates.map(&:created_at).min
      candidates.select { |block| block.created_at <= earliest + BLOCK_CREATION_WINDOW }
    end

    # Pairs we must not clear because a card-testing velocity rule wanted the very same row.
    #
    # PlatformBlock.add! keeps one row per (type, value) pair and re-activates it rather than
    # inserting a second one, so a single row can be simultaneously the mistaken block from the
    # decline and the deliberate block from a velocity rule that fired in the same transition. The
    # time clustering above cannot tell those apart — the two writes are the same write. Clearing
    # such a row would silently switch velocity enforcement off for that browser, email, address or
    # card, which is the one outcome this cleanup must never produce.
    #
    # So the velocity rules are re-run against the same history they saw, and everything they would
    # have blocked is left alone. Deliberately fail-closed in two ways: the counts cover the whole
    # span in which the failure could have happened rather than a single instant, and the feature
    # flags that gate the live rules are ignored. Both err towards protecting a row, at the cost of
    # occasionally leaving a genuinely mistaken block for a human to clear by hand.
    def velocity_protected_pairs(purchase)
      as_of = possible_failure_window(purchase).end
      protected_pairs = []

      # Purchase::Blockable#block_buyer_based_on_recent_failures! calls block_buyer!, which blocks
      # every identifier on the purchase, so nothing about this buyer can be cleared.
      recent_email_or_browser_failures =
        distinct_failed_fingerprints(as_of, Purchase::Blockable::CARD_TESTING_WATCH_PERIOD)
          .where("email = ? or browser_guid = ?", purchase.email, purchase.browser_guid)
      return blocked_pairs_for(purchase) if velocity_threshold_met?(recent_email_or_browser_failures)

      # Purchase::Blockable#ban_fraudulent_buyer_browser_guid! blocks the browser only, and counts
      # over all time rather than a window.
      if purchase.browser_guid.present?
        browser_failures = distinct_failed_fingerprints(as_of).where(browser_guid: purchase.browser_guid)
        protected_pairs << [PlatformBlock::TYPES[:browser_guid], purchase.browser_guid] if velocity_threshold_met?(browser_failures)
      end

      # Purchase::Blockable#block_ip_address_based_on_recent_failures! blocks the address only.
      if purchase.ip_address.present?
        ip_failures = distinct_failed_fingerprints(as_of, Purchase::Blockable::CARD_TESTING_IP_ADDRESS_WATCH_PERIOD)
                        .where(ip_address: purchase.ip_address)
        protected_pairs << [PlatformBlock::TYPES[:ip_address], purchase.ip_address] if velocity_threshold_met?(ip_failures)
      end

      protected_pairs
    end

    # The failed card fingerprints a velocity rule would have counted at the moment of the failure:
    # only rows that already existed then, and only within the rule's own watch period.
    def distinct_failed_fingerprints(as_of, watch_period = nil)
      scope = Purchase.failed.stripe.with_stripe_fingerprint
                      .select("distinct stripe_fingerprint")
                      .where(created_at: ..as_of)
      watch_period ? scope.where(created_at: (as_of - watch_period)..) : scope
    end

    def velocity_threshold_met?(scope)
      scope.count >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    # When the failure that wrote the blocks could have happened: at creation at the earliest, and
    # at the SCA deadline at the latest, plus the window for clock skew on either side.
    def possible_failure_window(purchase)
      (purchase.created_at - BLOCK_CREATION_WINDOW)..
        (purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA + BLOCK_CREATION_WINDOW)
    end

    def blocked_pairs_for(purchase)
      emails = [purchase.email, purchase.paypal_email, purchase.gifter_email, purchase.purchaser_email]
      fingerprints = [purchase.charge_processor_fingerprint, *possible_recent_stripe_fingerprints(purchase)]

      pairs = emails.compact_blank.uniq.map { [PlatformBlock::TYPES[:email], _1] }
      pairs += fingerprints.compact_blank.uniq.map { [PlatformBlock::TYPES[:charge_processor_fingerprint], _1] }
      pairs << [PlatformBlock::TYPES[:browser_guid], purchase.browser_guid] if purchase.browser_guid.present?
      pairs << [PlatformBlock::TYPES[:ip_address], purchase.ip_address] if purchase.ip_address.present?
      pairs
    end

    # The cards that Purchase::Blockable#recent_stripe_fingerprint could have returned back when the
    # block was created — "the buyer's most recent card" as of that moment, not as of today.
    #
    # Calling the live method here would return whatever card the buyer has used since, so a buyer
    # who moved on to a new card after being blocked would have that new card's fingerprint checked
    # (it was never blocked) while the row the old rule actually wrote went unnoticed. The buyer
    # stays unable to pay with the older card while the run reports them cleared.
    #
    # Which single card it was cannot be pinned down, because the moment of failure cannot be:
    # purchases carry no failed_at, and a charge held for Strong Customer Authentication fails
    # minutes after it was created, by which time the buyer may have started another purchase that
    # the original call would have picked instead. Bounding on this purchase's own id assumes the
    # earliest possibility and misses exactly that case. So collect every card that was on record by
    # the end of the window in which the failure could have happened, and let the rest of the checks
    # decide: a fingerprint only gets cleared if a matching row was actually written in the same
    # burst of inserts as the rest of this purchase's blocks, by automation, and no velocity rule
    # wanted it. Every card in the set belongs to this buyer's own history, which is the same set the
    # old rule drew from.
    def possible_recent_stripe_fingerprints(purchase)
      Purchase.with_stripe_fingerprint
              .where("purchaser_id = ? or email = ?", purchase.purchaser_id, purchase.email)
              .where("purchases.id <= :id OR purchases.created_at <= :as_of",
                     id: purchase.id, as_of: possible_failure_window(purchase).end)
              .distinct
              .pluck(:stripe_fingerprint)
    end
end
