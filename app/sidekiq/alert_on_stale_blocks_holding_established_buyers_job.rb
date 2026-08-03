# frozen_string_literal: true

# Reports buyers with settled payment history sitting behind an active platform block, keyed on the
# BLOCKS rather than on recent checkout failures (gumroad-private#1746).
#
# AlertOnBlockedEstablishedBuyersJob keys on recent failures, so it only sees buyers who tried
# lately. A block is not retryable, so a buyer refused once may never generate another failure row
# and stays outside that job's reach no matter how long the block stands. Keying on the blocks is
# what reaches them.
#
# Reports only; clearing a block stays a human decision.
class AlertOnStaleBlocksHoldingEstablishedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Only `email` blocks. Their object_value IS the buyer's identity, so history joins to the block
  # directly. The other types cannot be resolved from the block alone: a browser_guid or card
  # fingerprint names a device rather than a person, and an email_domain covers everyone on that
  # domain, so "the buyer behind this block" is not a question those rows can answer without a
  # failure row to anchor on — which is exactly what the failure-keyed job already has.
  BLOCK_TYPE = PlatformBlock::TYPES[:email]

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

  def perform
    scan = scan_for_stale_blocks
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:stale].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Stale blocks holding established buyers", message_for(scan))
  end

  private
    # One entry per active block standing in front of a buyer with settled history, in the report's
    # own ranking. `truncated` means the candidate window was cut short, so the counts are floors.
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
      # Advance past what this run judged. Saved before the counting work so a later failure cannot
      # pin the cursor and re-report the same page forever.
      save_cursor(candidates.last.id) if candidates.any?

      stale = []
      candidates.each_slice(HISTORY_COUNT_BATCH) do |batch|
        emails = batch.map { |block| block.object_value.downcase }

        settled = settled_purchase_counts(emails)
        next if settled.empty?

        settled = reject_disputed(settled)
        next if settled.empty?

        batch.each do |block|
          email = block.object_value.downcase
          count = settled[email]
          next if count.nil?

          stale << {
            email: block.object_value,
            settled_purchases: count,
            blocked_at: block.blocked_at,
          }
        end
      end

      { stale: report_order(stale), truncated: }
    end

    # Active email blocks nobody is named on, oldest first, one over the candidate budget so that
    # exhausting it is distinguishable from a table holding exactly that many.
    #
    # Oldest first because age is the whole complaint: a block written years ago that still refuses a
    # long-standing customer is the one a human should see, and a recent row is more likely to be a
    # velocity rule firing for cause.
    #
    # `blocked_by: nil` keeps this to unattended rows. A named block is a decision about this buyer,
    # not a rule that outlived itself. Not airtight — PlatformBlock.add! overwrites blocked_by on
    # every re-block, so a human's row a rule later re-triggered arrives here as unattended, which is
    # why the report tells its reader to re-check rather than presenting a line as proof.
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

    # Downcased email => settled non-free purchase count, using the same constants and veto scopes as
    # Purchase::Blockable#buyer_has_clean_payment_history?: purchases old enough for a cardholder to
    # have disputed them, none refunded, none charged back.
    #
    # ⚠️ It is NOT the same predicate. The real gate returns false on a blank stripe_fingerprint and
    # counts history on the CARD; this counts on the EMAIL, because a block value is an address and
    # there is no card in hand to key on. So this is deliberately WIDER: three settled PayPal
    # purchases, or three on three different one-use cards, clear here and would not clear there.
    # Email is also a weaker identity than a card — a line here can pair one person's block with
    # another's history. Both are why the report asks its reader to re-check before clearing anything
    # and why nothing here writes.
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

    def message_for(scan)
      stale = scan[:stale]
      lines = stale.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stale.size - lines.size

      [
        headline(stale.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} active blocks, so this is a floor — the backlog is larger than the count above." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "This scan keys on active blocks, not on recent checkout failures — so unlike the " \
          "failure-keyed report it reaches buyers who never retried. It does NOT query attempts, so " \
          "a line here may or may not have tried recently. " \
          "A line is also not proof the block is stale: a velocity rule writes `blocked_by` nil too, so " \
          "check the rules before unblocking, and remember `unblock_buyer!` clears the buyer's whole " \
          "identifier set rather than one row (see gumroad-private#1746).",
      ].compact.join("\n")
    end

    # Oldest block first. Age is what makes a line worth reading here: unlike the failure-keyed
    # report there is no recent attempt to rank by, and the buyer stuck since 2021 is the one whose
    # block is least likely to still be justified.
    def report_order(stale)
      stale.sort_by { |entry| [entry[:blocked_at].to_i, -entry[:settled_purchases]] }
    end

    def line_for(entry)
      "• #{entry[:email]} — #{entry[:settled_purchases]} settled purchases, " \
        "blocked by email since #{entry[:blocked_at].to_date} (no recent attempt)"
    end

    def headline(count, truncated)
      return "No active email block on the scanned page stands in front of an established buyer, but the scan was truncated, so this is not evidence that none do." if count.zero?

      "#{truncated ? "At least " : ""}#{count} active email block#{"s" if count != 1} " \
        "#{count == 1 ? "is" : "are"} holding a buyer with " \
        "#{Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY}+ settled purchases."
    end
end
