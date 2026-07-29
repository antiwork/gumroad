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
#   * it was last blocked in the same moment that purchase failed, since the old rule ran inside
#     the failure transition. A purchase does not always fail when it is created — one needing
#     Strong Customer Authentication can fail up to fifteen minutes later — so the search covers
#     that whole span and then keeps only the rows written within a couple of minutes of the
#     earliest one, which is how the old rule's single burst of inserts looks. This is what keeps
#     the sweep away from a velocity block written minutes later by a different code path, and
#     away from an IP address that was blocked because of somebody else entirely;
#   * the burst includes a row of a type only block_buyer! ever wrote unattended — an email or a
#     card — which is what distinguishes it from the automations that block an IP address or a
#     browser on their own. See #matches_block_buyer_signature?;
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
  # rule blocked every row synchronously in the state transition, so this only has to cover the
  # handful of writes plus clock skew between the app and the database.
  BLOCK_CREATION_WINDOW = 2.minutes

  # How many of the buyer's cards to reconstruct as candidates for the one the old rule blocked.
  # See #possible_recent_stripe_fingerprints.
  RECONSTRUCTED_FINGERPRINT_LIMIT = 10

  def initialize(dry_run: true, lookback: DEFAULT_LOOKBACK)
    @dry_run = dry_run
    @lookback = lookback
  end

  # Returns one row per buyer we cleared (or, in a dry run, would clear), each listing the blocks
  # involved, so the run can be pasted into the issue as a record of what changed.
  #
  # A dry run lists the same blocks under every candidate purchase that would have cleared them,
  # where a real run clears them at the first purchase and finds nothing at the second. So the
  # union of pairs matches between the two runs, but the per-purchase rows do not — read the dry
  # run as "these blocks would be cleared", not as a preview of the report a real run prints.
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
    #     later), and the blocks were written in that later transition. A window centred on the
    #     purchase's creation misses those rows entirely and leaves the buyer blocked after a sweep
    #     that reported them cleared.
    #   * simply widening the window to cover the whole SCA period would let a row written minutes
    #     apart, by another code path, look like part of this failure.
    #
    # So: look in the outer bound of when the failure could have happened, then require that the
    # rows we clear are tight around the earliest of them. The old rule wrote all of its rows in one
    # synchronous transition, so genuine rows sit within seconds of each other; a velocity block
    # from a separate event minutes away falls outside that inner window and is left alone.
    #
    # Time is read from blocked_at, never created_at. PlatformBlock.add! is create_or_find_by!
    # followed by an update, so re-blocking an identifier that was ever blocked before reuses the
    # existing row and leaves created_at at the row's first-ever insert. created_at therefore says
    # when we first heard of the identifier, while blocked_at says when this block was written —
    # the only one of the two that can be compared against the moment of failure. Using created_at
    # got this wrong in both directions: an IP or email with an older row (expired six-month IP
    # block, a previous block since lifted) never matched any window and was left blocked by a run
    # that reported the buyer cleared, and a row the bug wrote long ago and a velocity rule
    # re-blocked last month still carried its old created_at, so it looked like part of the old
    # burst and would have been cleared out from under live enforcement.
    def mistaken_blocks_for(purchase)
      pairs = blocked_pairs_for(purchase) - velocity_protected_pairs(purchase)
      return [] if pairs.empty?

      candidates = PlatformBlock.active
                                .where(blocked_by: nil, blocked_at: possible_failure_window(purchase))
                                .where(pairs.map { "(object_type = ? AND object_value = ?)" }.join(" OR "), *pairs.flatten)
                                .to_a
      return [] if candidates.empty?

      earliest = candidates.map(&:blocked_at).min
      burst = candidates.select { |block| block.blocked_at <= earliest + BLOCK_CREATION_WINDOW }
      matches_block_buyer_signature?(burst) ? burst : []
    end

    # Types that only Purchase::Blockable#block_buyer! ever wrote without a person behind it, and so
    # identify a burst as this bug's rather than another automation's.
    #
    # Every other unattended writer of a blocked_by: nil row blocks one identifier on its own: an IP
    # address (BlockSuspendedAccountIpWorker after a risk suspension,
    # #block_ip_address_based_on_recent_failures!, #block_fraudulent_free_purchases!), a browser
    # (#ban_fraudulent_buyer_browser_guid!) or a product (#block_purchases_on_product!). None of
    # them blocks an email address or a card. Mass admin blocks and the chargeback auto-block go
    # through BlockObjectWorker and record a blocked_by, so they are already excluded.
    BLOCK_BUYER_ONLY_TYPES = [PlatformBlock::TYPES[:email], PlatformBlock::TYPES[:charge_processor_fingerprint]].freeze

    # Whether a burst of blocks written in one moment came from block_buyer! rather than from one of
    # the single-identifier automations above.
    #
    # Without this, a candidate purchase only has to share an IP address with somebody suspended in
    # the same couple of minutes — carrier NAT, an office, a VPN exit — for the sweep to clear that
    # unrelated six-month suspension block as if this bug had written it. The velocity rules are
    # re-run and protected separately, but the suspension worker cannot be reconstructed from a
    # purchase, so the burst has to identify itself. block_buyer! always blocked the purchase's own
    # email and card alongside the browser and the address, so a burst carrying neither is not ours
    # and the IP or browser row in it belongs to something else.
    def matches_block_buyer_signature?(blocks)
      blocks.any? { |block| BLOCK_BUYER_ONLY_TYPES.include?(block.object_type) }
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
      window = possible_failure_window(purchase)
      protected_pairs = []

      # Purchase::Blockable#block_buyer_based_on_recent_failures! calls block_buyer!, which blocks
      # every identifier on the purchase, so nothing about this buyer can be cleared.
      recent_email_or_browser_failures =
        distinct_failed_stripe_fingerprints(window, Purchase::Blockable::CARD_TESTING_WATCH_PERIOD)
          .where("email = ? or browser_guid = ?", purchase.email, purchase.browser_guid)
      return blocked_pairs_for(purchase) if velocity_threshold_met?(recent_email_or_browser_failures)

      # Purchase::Blockable#ban_fraudulent_buyer_browser_guid! blocks the browser only, and counts
      # over all time rather than a window, and — unlike the two rules above — over every failed
      # purchase carrying a card fingerprint, whatever charge processor it went through.
      if purchase.browser_guid.present?
        browser_failures = Purchase.failed.with_stripe_fingerprint
                                   .select("distinct stripe_fingerprint")
                                   .where(created_at: ..window.end)
                                   .where(browser_guid: purchase.browser_guid)
        protected_pairs << [PlatformBlock::TYPES[:browser_guid], purchase.browser_guid] if velocity_threshold_met?(browser_failures)
      end

      # Purchase::Blockable#block_ip_address_based_on_recent_failures! blocks the address only.
      if purchase.ip_address.present?
        ip_failures = distinct_failed_stripe_fingerprints(window, Purchase::Blockable::CARD_TESTING_IP_ADDRESS_WATCH_PERIOD)
                        .where(ip_address: purchase.ip_address)
        protected_pairs << [PlatformBlock::TYPES[:ip_address], purchase.ip_address] if velocity_threshold_met?(ip_failures)
      end

      protected_pairs
    end

    # The failed Stripe card fingerprints a velocity rule would have counted at the moment of the
    # failure: only purchases that already existed then, and only within the rule's own watch
    # period.
    #
    # The watch period is measured backwards from the START of the window rather than its end, so
    # the range covers every period the live rule could have used whenever it ran. Measuring from
    # the end would drop the oldest minutes of the real window, undercount, and let a row a
    # velocity rule genuinely wanted look clearable.
    def distinct_failed_stripe_fingerprints(window, watch_period)
      Purchase.failed.stripe.with_stripe_fingerprint
              .select("distinct stripe_fingerprint")
              .where(created_at: (window.begin - watch_period)..window.end)
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
    # end of the window in which the failure could have happened, and let the rest of the checks
    # decide: a fingerprint only gets cleared if a matching row was actually blocked in the same
    # burst as the rest of this purchase's blocks, by automation, and no velocity rule wanted it.
    #
    # Capped, and ordered newest first, because the set is only as private as the email address it
    # is keyed on. The old rule blocked exactly one card, the most recent; a throwaway or shared
    # address (info@, a typo domain, a mailbox many guests have reused) can carry hundreds of
    # strangers' purchases, and without a cap every one of their cards would become a clearable pair
    # and an OR clause in the query below. The newest few around the window are the only ones the
    # old rule could plausibly have picked.
    def possible_recent_stripe_fingerprints(purchase)
      Purchase.with_stripe_fingerprint
              .where("purchaser_id = ? or email = ?", purchase.purchaser_id, purchase.email)
              .where("purchases.id <= :id OR purchases.created_at <= :as_of",
                     id: purchase.id, as_of: possible_failure_window(purchase).end)
              .order(id: :desc)
              .limit(RECONSTRUCTED_FINGERPRINT_LIMIT)
              .pluck(:stripe_fingerprint)
              .uniq
    end
end
