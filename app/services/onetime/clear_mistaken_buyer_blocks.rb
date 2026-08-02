# frozen_string_literal: true

# One-off cleanup for the buyers that Purchase::Blockable#ban_buyer_on_fraud_related_error_code!
# platform-blocked before it learned to check payment history (gumroad-private#1480). The old rule
# blocked the browser, every email on the purchase, the IP and the card on any fraud-flavoured
# decline code — including "lost card"/"pickup card", which issuers also use for ordinary
# reissues. The code no longer writes those rows and nothing expires them (only the IP row has an
# expiry at all), so they have to be cleared here.
#
# Run from a console; reports without changing anything unless asked to clear:
#
#   Onetime::ClearMistakenBuyerBlocks.new.process                    # report only
#   Onetime::ClearMistakenBuyerBlocks.new(dry_run: false).process     # clear them
#
# The risk is clearing a row somebody still means, so a row is only touched when it was written
# unattended (blocked_by nil, which excludes admin and chargeback blocks), in the burst that this
# purchase's failure wrote, carrying block_buyer!'s own signature, and no velocity rule wanted it.
class Onetime::ClearMistakenBuyerBlocks
  # How far back to look for the decline that caused the block.
  DEFAULT_LOOKBACK = 1.year

  # The old rule wrote every row synchronously inside the failure transition, so this only has to
  # cover a handful of writes plus app/database clock skew.
  BLOCK_CREATION_WINDOW = 2.minutes

  RECONSTRUCTED_FINGERPRINT_LIMIT = 10

  def initialize(dry_run: true, lookback: DEFAULT_LOOKBACK)
    @dry_run = dry_run
    @lookback = lookback
  end

  # A dry run repeats the same blocks under every candidate purchase that would have cleared them,
  # where a real run clears them at the first and finds nothing at the second. The union of pairs
  # matches between the two runs; the per-purchase rows do not.
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

    # The active, unattended blocks this purchase's failure wrote, as (type, value) pairs — matched
    # as pairs, since an email-shaped value under one type must not clear a row of another.
    #
    # Purchases carry no failed_at, and one held for SCA fails up to
    # ChargeProcessor::TIME_TO_COMPLETE_SCA after creation, so the search has to span that whole
    # period; but a window that wide would also swallow an unrelated block written minutes away.
    # Hence the two stages: search the outer bound, then keep only the rows tight around the
    # earliest, which is how the old rule's single synchronous burst looks.
    #
    # Time is blocked_at, never created_at: PlatformBlock.add! is create_or_find_by! plus an
    # update, so created_at is when we first heard of the identifier, not when this block was
    # written. created_at fails in both directions — a previously-blocked identifier matches no
    # window and stays blocked, and a bug-era row a velocity rule re-blocked last month still looks
    # like part of the old burst.
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

    # Every other unattended writer of a blocked_by: nil row blocks a single IP
    # (BlockSuspendedAccountIpWorker, #block_ip_address_based_on_recent_failures!,
    # #block_fraudulent_free_purchases!), browser (#ban_fraudulent_buyer_browser_guid!) or product
    # (#block_purchases_on_product!) — never an email or a card. So these two types identify a
    # burst as block_buyer!'s.
    BLOCK_BUYER_ONLY_TYPES = [PlatformBlock::TYPES[:email], PlatformBlock::TYPES[:charge_processor_fingerprint]].freeze

    # Without this, sharing an IP with somebody suspended in the same two minutes (carrier NAT, an
    # office, a VPN exit) is enough to clear their unrelated suspension block. Velocity rules are
    # re-run and protected below, but BlockSuspendedAccountIpWorker cannot be reconstructed from a
    # purchase, so the burst has to identify itself: block_buyer! always blocked the email and card
    # too, so a burst carrying neither is not ours.
    def matches_block_buyer_signature?(blocks)
      blocks.any? { |block| BLOCK_BUYER_ONLY_TYPES.include?(block.object_type) }
    end

    # Pairs a card-testing velocity rule wanted, which must survive. One row per (type, value) is
    # re-activated rather than duplicated, so the mistaken block and a velocity block firing in the
    # same transition are literally the same row — the time clustering above cannot separate them,
    # and clearing it would switch velocity enforcement off for that identifier.
    #
    # So re-run the rules against the history they saw. Fail-closed on purpose: counts span the
    # whole possible-failure window, and the feature flags gating the live rules are ignored. Both
    # can leave a genuinely mistaken block for a human to clear by hand.
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
      # over all time rather than a window. Same countable scope as the live rule: counting rows
      # it ignores would retain exactly the outage-manufactured blocks this cleanup exists to
      # clear.
      if purchase.browser_guid.present?
        browser_failures = Purchase.countable_card_testing_failures
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

    # The fingerprints a velocity rule would have counted at the moment of failure. The watch
    # period runs back from the START of the window, not its end, so the range covers every period
    # the live rule could have used; from the end it would undercount and expose a wanted row.
    def distinct_failed_stripe_fingerprints(window, watch_period)
      Purchase.countable_card_testing_failures
              .where(created_at: (window.begin - watch_period)..window.end)
    end

    def velocity_threshold_met?(scope)
      Purchase.distinct_card_count(scope) >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    # When the failure could have happened: creation at the earliest, the SCA deadline at the
    # latest, plus clock skew either side.
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

    # What Purchase::Blockable#recent_stripe_fingerprint could have returned when the block was
    # written — the buyer's most recent card as of THEN. Calling the live method would return a card
    # the buyer has used since, which was never blocked, leaving the real row untouched by a run
    # that reports the buyer cleared.
    #
    # Which single card it was is unknowable (no failed_at, and an SCA charge fails minutes later,
    # by which time another purchase may have overtaken it), so take every card on record by the end
    # of the window and let the burst/velocity checks decide.
    #
    # Capped and newest-first because this is keyed on an email: a shared or throwaway address can
    # carry hundreds of strangers' purchases, and each card becomes a clearable pair and an OR
    # clause below. Keyed as the old rule keyed its own lookup — `purchaser_id = ?` is dead on a
    # guest checkout (NULL comparison is never true), which narrows to the email alone. Keep it:
    # a NULL-safe `<=>` would match every guest at once and lift strangers' live blocks.
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
