# frozen_string_literal: true

# Clears active platform blocks standing in front of buyers with settled payment history, keyed on
# the BLOCKS rather than on recent checkout failures (gumroad-private#1746).
#
# AlertOnBlockedEstablishedBuyersJob keys on recent failures, so it only sees buyers who tried
# lately. A block is not retryable, so a buyer refused once may never generate another failure row
# and stays outside that job's reach no matter how long the block stands. Keying on the blocks is
# what reaches them.
#
# Auto-clears a block when the buyer clears the clean-history gate AND the email is not linked to a
# suspended account — Sahil, gumroad-private#1746: "Auto clear if not linked to suspended accounts
# i.e fraud." Anything linked to a suspension is held and reported for a human instead.
class AlertOnStaleBlocksHoldingEstablishedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Only `email` blocks. Their object_value IS the buyer's identity, so history joins to the block
  # directly. The other types cannot be resolved from a block alone: a browser_guid or card
  # fingerprint names a device rather than a person, and an email_domain covers everyone on that
  # domain, so "the buyer behind this block" is not a question those rows can answer on their own.
  # Browser and card rows are cleared only as siblings of a cleared email block (#burst_siblings).
  BLOCK_TYPE = PlatformBlock::TYPES[:email]

  # The account-side veto: a suspension is a decision about this person, independent of whether
  # the block row itself carries `blocked_by`. Same states User.not_suspended excludes, so this
  # cannot drift from what the rest of the app calls "suspended".
  SUSPENDED_RISK_STATES = %w[suspended_for_fraud suspended_for_tos_violation].freeze

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many blocks get their buyer's history counted per run. Everything past
  # it is unscanned in THIS run, and the report says so rather than presenting its count as the total.
  # Measured 40,000+ candidate blocks, so a full pass is out of reach for one run — successive runs
  # resume from a saved cursor and wrap, so the backlog is covered over ~8 weeks rather than the same
  # page being re-reported forever.
  MAX_CANDIDATES_SCANNED = 5_000

  # Blocks are counted in batches to keep each grouped query's IN list bounded.
  HISTORY_COUNT_BATCH = 500

  # Purchase#block_buyer! writes the browser and card rows in the same synchronous burst as the email
  # row. Clearing only the email leaves the buyer refused on the card or device, and no other job
  # clears those once the buyer stops retrying. IP rows are left alone: they are shared and expire.
  SIBLING_TYPES = [PlatformBlock::TYPES[:browser_guid], PlatformBlock::TYPES[:charge_processor_fingerprint]].freeze
  SIBLING_BURST_WINDOW = 2.minutes

  # A shared address can carry thousands of purchases; past this many distinct values the rest stay
  # blocked rather than turning one clear into an unbounded lookup.
  MAX_SIBLING_VALUES = 200
  SUBSCRIPTION_CARD_LOOKUP_LIMIT = 20
  # Indian-card renewals can stay in progress for 26 hours before the failure webhook writes the block.
  RENEWAL_DECLINE_LOOKBACK = 2.days

  def perform
    scan = scan_for_stale_blocks
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:cleared].empty? && scan[:held].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Stale blocks holding established buyers", message_for(scan))
  end

  private
    # Clears every active block standing in front of a buyer with settled history whose email is not
    # linked to a suspended account, and reports the rest. `truncated` means the candidate window was
    # cut short, so the counts are floors.
    def scan_for_stale_blocks
      after_id = current_cursor
      candidates = candidate_blocks(after_id)

      # Exhausted the backlog: wrap to the beginning so the sweep is a loop rather than a dead end.
      if candidates.empty? && after_id.positive?
        save_cursor(0)
        candidates = candidate_blocks(0)
      end

      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)

      cleared = []
      held = []
      candidates.each_slice(HISTORY_COUNT_BATCH) do |batch|
        emails = batch.map { |block| block.object_value.downcase }

        settled = settled_purchase_counts(emails)
        next if settled.empty?

        settled = reject_disputed(settled)
        next if settled.empty?

        suspended = linked_to_suspended_account(settled.keys)

        batch.each do |block|
          email = block.object_value.downcase
          count = settled[email]
          next if count.nil?

          entry = { email: block.object_value, settled_purchases: count, blocked_at: block.blocked_at }

          if suspended.include?(email)
            held << entry
          else
            # Re-checked here, immediately before the write, rather than trusting the batch's
            # snapshot — a concurrent admin block, a newly-suspended account, or a chargeback
            # recorded after the batch queries ran would otherwise get cleared by a decision that
            # was already stale by the time it reached this line.
            block.reload
            still_active = block.blocked_at.present? && (block.expires_at.nil? || block.expires_at > Time.current)
            if still_active && block.blocked_by.nil? && !newly_disputed_or_suspended?(email)
              window = burst_window(block)
              siblings = burst_siblings(email, window)
              # Siblings first, the email row last: they are only reachable through this block, so a
              # write that raises mid-burst has to leave the anchor active or the retry has no
              # candidate to re-anchor on and the sibling rows stay blocked forever.
              # Re-read at the write too: an admin re-block since the lookup rewrites both columns.
              siblings = siblings.select { |sibling| unattended_in_window?(sibling.reload, window) }
              siblings.each(&:unblock!)
              # The email row loaded above is stale once siblings have been written.
              block.reload
              if unattended_in_window?(block, window)
                block.unblock!
                cleared << entry.merge(siblings: siblings.size)
              else
                held << entry.merge(reason: :changed_since_scan)
              end
            else
              held << entry.merge(reason: :changed_since_scan)
            end
          end
        end
      end

      # Advance past what this run judged. Only reached if every batch's history-count and dispute
      # queries completed without raising — an exception mid-page propagates before this line, so
      # Sidekiq's retry re-reads the same unmoved cursor and re-scans the failed page instead of
      # skipping past it.
      save_cursor(candidates.last.id) if candidates.any?

      { cleared: report_order(cleared), held: report_order(held), truncated: }
    end

    # Active email blocks nobody is named on, one over the candidate budget so that exhausting it is
    # distinguishable from a table holding exactly that many.
    #
    # Ordered by id, not age: id is the keyset the cursor resumes from, and `blocked_at` is not
    # monotonic in id because PlatformBlock.add! reuses the row and rewrites blocked_at on re-block.
    # Age-ranking happens per page in `report_order`, so a run reports its own page oldest-first
    # rather than the backlog's oldest rows.
    #
    # `blocked_by: nil` keeps this to unattended rows. A named block is a decision about this buyer,
    # not a rule that outlived itself. Not airtight — PlatformBlock.add! overwrites blocked_by on
    # every re-block, so a human's row a rule later re-triggered arrives here as unattended, which is
    # why the account-suspension veto below is a second, independent check rather than trusting this
    # column alone.
    def candidate_blocks(after_id)
      PlatformBlock.active
                   .where(object_type: BLOCK_TYPE, blocked_by: nil)
                   .where.not(object_value: nil)
                   .where("platform_blocks.id > ?", after_id)
                   .order(id: :asc)
                   .limit(MAX_CANDIDATES_SCANNED + 1)
                   .to_a
    end

    # Where this run starts: the id the last run stopped at. Ordering is by id rather than
    # `blocked_at` so the stopping point is a keyset the next run resumes from exactly.
    def current_cursor
      $redis.get(RedisKey.stale_block_sweep_cursor).to_i
    rescue => e
      # A lost cursor re-reports the first page, which is noisy but not wrong. Losing the run is worse.
      ErrorNotifier.notify(e)
      0
    end

    def save_cursor(cursor_id)
      $redis.set(RedisKey.stale_block_sweep_cursor, cursor_id)
    rescue => e
      ErrorNotifier.notify(e)
    end

    # blocked_at, not created_at: PlatformBlock.add! reuses the row, so created_at is first sighting.
    def burst_window(block)
      (block.blocked_at - SIBLING_BURST_WINDOW)..(block.blocked_at + SIBLING_BURST_WINDOW)
    end

    # The unattended browser/card rows written in this email block's own burst, restricted to values
    # on this buyer's SUCCESSFUL purchases: anyone can type this email into a failed attempt, so a
    # card tester's card or browser must not ride along. A row a live rule still wants stays.
    def burst_siblings(email, window)
      purchases = Purchase.successful.where(email:)
      stripe_fingerprints, other_visuals = card_sibling_values(purchases)
      values = {
        PlatformBlock::TYPES[:browser_guid] => purchases.where.not(browser_guid: [nil, ""]).distinct.limit(MAX_SIBLING_VALUES).pluck(:browser_guid),
        PlatformBlock::TYPES[:charge_processor_fingerprint] => (stripe_fingerprints + other_visuals).uniq,
      }
      siblings = SIBLING_TYPES.flat_map do |object_type|
        next [] if values[object_type].empty?

        PlatformBlock.active.where(object_type:, object_value: values[object_type], blocked_by: nil, blocked_at: window).to_a
      end
      return [] if velocity_still_fires?(email, siblings)

      siblings.reject { |sibling| velocity_protected_browser?(sibling) || fraud_rule_still_wants_card?(sibling, stripe_values: stripe_fingerprints) }
    end

    # Same split as Purchase#charge_processor_fingerprint for the visual: a Stripe masked visual is
    # not a block key. Fingerprints are kept from every processor, because a block can also be
    # written from recent_stripe_fingerprint.
    def card_sibling_values(purchases)
      stripe_id = StripeChargeProcessor.charge_processor_id
      stripe_fingerprints = purchases.where.not(stripe_fingerprint: [nil, ""])
                                      .distinct.limit(MAX_SIBLING_VALUES)
                                      .pluck(:stripe_fingerprint)
      other_visuals = purchases.where("charge_processor_id IS NULL OR charge_processor_id != ?", stripe_id)
                               .where.not(card_visual: [nil, ""])
                               .distinct.limit(MAX_SIBLING_VALUES)
                               .pluck(:card_visual)
      [stripe_fingerprints, other_visuals]
    end

    # ban_buyer_on_fraud_related_error_code! blocks the card, not the person, so only a card that
    # rule would still block may stay: one indexed decline is enough for a Stripe fingerprint, a
    # renewal can block the card it charged, and other processors are keyed by visual.
    def fraud_rule_still_wants_card?(sibling, stripe_values:)
      return false unless sibling.object_type == PlatformBlock::TYPES[:charge_processor_fingerprint]

      value = sibling.object_value
      return false if value.blank?

      if stripe_values.include?(value)
        return true if subscription_card_fraud_decline?(value, sibling.blocked_at)

        decline = stripe_fraud_decline(value)
        return !decline.buyer_has_clean_payment_history? if decline

        return false
      end

      other_processor_fraud_still_wants?(value)
    end

    def stripe_fraud_decline(value)
      Purchase.failed
              .where(charge_processor_id: StripeChargeProcessor.charge_processor_id, stripe_fingerprint: value)
              .where(fraud_decline_sql, codes: PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES)
              .limit(1)
              .first
    end

    # A renewal blocks the card it charged only when that charge is recurring and an earlier settled
    # purchase of the same subscription used that card id — the writer's own condition
    # (#subscription_card_fingerprint), which a count of fraud-coded failures cannot stand in for.
    # purchases.credit_card_id has no index, so the created_at window has to drive the lookup.
    def subscription_card_fraud_decline?(value, blocked_at)
      return false if blocked_at.blank?

      declines = Purchase.failed
                         .where(created_at: (blocked_at - RENEWAL_DECLINE_LOOKBACK)..(blocked_at + Onetime::ClearMistakenBuyerBlocks::BLOCK_CREATION_WINDOW))
                         .where(credit_card_id: CreditCard.where(stripe_fingerprint: value).select(:id))
                         .where.not(subscription_id: nil)
                         .where(fraud_decline_sql, codes: PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES)
                         .order(created_at: :desc)
                         .limit(SUBSCRIPTION_CARD_LOOKUP_LIMIT)
                         .to_a

      declines.any? do |purchase|
        purchase.is_recurring_subscription_charge &&
          purchase.send(:subscription_card_fingerprint) == value &&
          !purchase.buyer_has_clean_payment_history?
      end
    end

    def other_processor_fraud_still_wants?(value)
      stripe_id = StripeChargeProcessor.charge_processor_id
      known_types = fraud_lookup_card_types
      return true if visual_fraud_still_wants?(value, stripe_id, card_types: known_types)
      return true if visual_fraud_still_wants?(value, stripe_id, card_types: [nil])

      visual_fraud_still_wants?(value, stripe_id, excluded_card_types: known_types)
    end

    def visual_fraud_still_wants?(value, stripe_id, card_types: nil, excluded_card_types: nil)
      scope = Purchase.failed
                      .where(card_visual: value)
                      .where("charge_processor_id IS NULL OR charge_processor_id != ?", stripe_id)
                      .where(fraud_decline_sql, codes: PurchaseErrorCode::AUTO_BLOCK_ERROR_CODES)
      scope = scope.where(card_type: card_types) if card_types
      scope = scope.where.not(card_type: excluded_card_types) if excluded_card_types
      declines = scope.limit(SUBSCRIPTION_CARD_LOOKUP_LIMIT).to_a
      return false if declines.empty?
      return true if declines.size == SUBSCRIPTION_CARD_LOOKUP_LIMIT

      declines.any? { |purchase| purchase.charge_processor_fingerprint == value && !purchase.buyer_has_clean_payment_history? }
    end

    def fraud_lookup_card_types
      CardType.constants(false).filter_map do |name|
        value = CardType.const_get(name)
        value if value.is_a?(String)
      end
    end

    def fraud_decline_sql
      "stripe_error_code IN (:codes) OR (stripe_error_code IS NULL AND error_code IN (:codes))"
    end

    def unattended_in_window?(sibling, window)
      sibling.blocked_by.nil? && sibling.blocked_at.present? && window.cover?(sibling.blocked_at) &&
        (sibling.expires_at.nil? || sibling.expires_at > Time.current)
    end

    # The 7-day card-testing rule, re-run against the history it saw. It counts the union for ONE
    # attempt — this email, or one browser — so each of the burst's browsers is checked against the
    # email on its own: pooling them would read four cards spread over two browsers as one attempt,
    # and the pool's cap could hide a browser that really does trip it.
    def velocity_still_fires?(email, siblings)
      browsers = siblings.filter_map { |sibling| sibling.object_value if sibling.object_type == PlatformBlock::TYPES[:browser_guid] }
      return email_or_browser_velocity_fires?(email, nil) if browsers.empty?

      browsers.any? { |guid| email_or_browser_velocity_fires?(email, guid) }
    end

    def email_or_browser_velocity_fires?(email, browser_guid)
      failures = Purchase.countable_card_testing_failures.where(created_at: Purchase::Blockable::CARD_TESTING_WATCH_PERIOD.ago..)
      failures = if browser_guid.present?
        failures.where("purchases.email = ? OR purchases.browser_guid = ?", email, browser_guid)
      else
        failures.where(email:)
      end
      Purchase.distinct_card_count(failures) >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    def velocity_protected_browser?(sibling)
      return false unless sibling.object_type == PlatformBlock::TYPES[:browser_guid]

      failures = Purchase.countable_card_testing_failures.where(browser_guid: sibling.object_value)
      Purchase.distinct_card_count(failures) >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    # Downcased email => settled non-free purchase count, using the same constants and veto scopes as
    # Purchase::Blockable#buyer_has_clean_payment_history?: purchases old enough for a cardholder to
    # have disputed them, none refunded, none charged back.
    #
    # ⚠️ It is NOT the same predicate. The real gate returns false on a blank stripe_fingerprint and
    # counts history on the CARD; this counts on the EMAIL, because a block value is an address and
    # there is no card in hand to key on. So this is deliberately WIDER: three settled PayPal
    # purchases, or three on three different one-use cards, clear here and would not clear there.
    # Email is also a weaker identity than a card — a line here can pair one person's block with
    # another's history. That is exactly why the account-suspension check below re-derives from the
    # purchases and the User row rather than trusting this grouping alone.
    #
    # Keyed on the downcased address for the same reason DecliningPlatformBlocks does it: the column
    # collates ci, so a mixed-case legacy row comes back under an arbitrary member's casing and would
    # not join to a lowercase block value.
    def settled_purchase_counts(emails)
      Purchase.successful.non_free.not_fully_refunded.not_chargedback_or_chargedback_reversed
              .where(created_at: ..Purchase::Blockable::MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY.ago)
              .where(email: emails)
              .group(:email)
              .count
              .transform_keys(&:downcase)
              .select { |_, count| count >= Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY }
    end

    # Drops buyers carrying an unreversed chargeback on ANY purchase, which the counts above only
    # excluded from the total: a buyer with three clean purchases and a fourth charged back would
    # otherwise read as established, and a chargeback is exactly what a block is for.
    def reject_disputed(settled)
      # The exact complement of the not_chargedback_or_chargedback_reversed scope the counts above
      # use, so the numerator and the veto cannot disagree about what a live dispute is.
      disputed = Purchase.where(email: settled.keys)
                         .where.not(chargeback_date: nil)
                         .where("purchases.flags & :bit = 0", bit: Purchase.flag_mapping["flags"][:chargeback_reversed])
                         .distinct
                         .pluck(:email)
                         .map(&:downcase)
                         .to_set

      settled.reject { |email, _| disputed.include?(email) }
    end

    # Downcased emails whose account side is linked to a suspension — either the email IS a
    # suspended account's own login email, or it appears as a purchaser/typed-in address on a
    # purchase whose account is suspended. Both directions matter: a suspended seller checking out
    # as a buyer under their own account, and a suspended account's owner typing that address into a
    # guest checkout, are both "linked to a suspended account" in Sahil's sense, and neither is
    # caught by the other query alone.
    def linked_to_suspended_account(emails)
      by_login = User.where(email: emails).where(user_risk_state: SUSPENDED_RISK_STATES)
                     .pluck(:email).map(&:downcase).to_set

      by_purchaser = Purchase.where(email: emails).where.not(purchaser_id: nil)
                            .joins(:purchaser).merge(User.where(user_risk_state: SUSPENDED_RISK_STATES))
                            .distinct.pluck(:email).map(&:downcase).to_set

      by_login | by_purchaser
    end

    # The batch-level `reject_disputed` and `linked_to_suspended_account` queries ran once, before
    # this row's write. A chargeback recorded, or an account suspended, in the gap between that
    # query and this `unblock!` would otherwise slip through unnoticed — re-deriving both from a
    # single email, right at the write, is what closes that gap rather than trusting a snapshot the
    # rest of the batch already moved past.
    def newly_disputed_or_suspended?(email)
      reject_disputed({ email => 1 }).empty? || linked_to_suspended_account([email]).any?
    end

    def message_for(scan)
      cleared = scan[:cleared]
      held = scan[:held]
      lines = cleared.first(MAX_REPORTED).map { |entry| line_for(entry, cleared: true) }
      held_lines = held.first(MAX_REPORTED - lines.size).map { |entry| line_for(entry, cleared: false) }
      omitted = (cleared.size - lines.size) + (held.size - held_lines.size)

      [
        headline(cleared.size, held.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} active blocks, so this is a floor — the backlog is larger than the count above." : nil),
        "",
        *lines,
        *held_lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Cleared lines were unblocked automatically: settled history, no unreversed chargeback, " \
          "and the email is not linked to a suspended account (Sahil, gumroad-private#1746). Held " \
          "lines qualified on history but are linked to a suspended account, or changed underneath " \
          "this run, so they were left blocked for a human to judge — remember `unblock_buyer!` " \
          "clears the buyer's whole identifier set rather than one row (see gumroad-private#1746).",
      ].compact.join("\n")
    end

    # Oldest block first. Age is what makes a line worth reading here: unlike the failure-keyed
    # report there is no attempt recency to rank by, and the buyer stuck since 2021 is the one whose
    # block is least likely to still be justified.
    def report_order(entries)
      entries.sort_by { |entry| [entry[:blocked_at].to_i, -entry[:settled_purchases]] }
    end

    def line_for(entry, cleared:)
      verb = cleared ? "cleared" : "held — linked to a suspended account"
      verb += " with #{entry[:siblings]} card/browser block#{"s" if entry[:siblings] != 1} from the same burst" if cleared && entry[:siblings].to_i.positive?
      "• #{entry[:email]} — #{entry[:settled_purchases]} settled purchases, #{verb}, " \
        "blocked by email since #{entry[:blocked_at].to_date}"
    end

    def headline(cleared_count, held_count, truncated)
      if cleared_count.zero? && held_count.zero?
        return "No active email block on the scanned page stands in front of an established buyer, but the scan was truncated, so this is not evidence that none do." if truncated

        return "No active email block on the scanned page stands in front of an established buyer."
      end

      prefix = truncated ? "At least " : ""
      "#{prefix}#{cleared_count} active email block#{"s" if cleared_count != 1} holding a buyer with " \
        "#{Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY}+ settled purchases " \
        "#{cleared_count == 1 ? "was" : "were"} cleared; #{held_count} more #{held_count == 1 ? "was" : "were"} held for review."
    end
end
