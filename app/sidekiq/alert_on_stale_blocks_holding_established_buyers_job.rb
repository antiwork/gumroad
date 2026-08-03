# frozen_string_literal: true

# Reports buyers with settled payment history sitting behind an active platform block, keyed on the
# BLOCKS rather than on recent failures (gumroad-private#1746).
#
# AlertOnBlockedEstablishedBuyersJob asks "who was refused lately, and is a block still holding
# them?" — so it only ever sees someone who tried recently. A block is not retryable, so a buyer
# refused once gives up and never generates another row; that job's own comment concedes they are
# then "invisible to this report forever". Measured 2026-08-03: 5,001 emails had a block-declined
# failure in a 30-day window while 39,701 active automated email blocks had none, the oldest written
# 2021-04-29, and 18% of a sample of those cleared the clean-history gate.
#
# This job asks the inverted question — "which active blocks are standing in front of a settled
# buyer?" — which reaches the ones who stopped trying. Overlap with the failure-keyed report is a
# duplicate line in an internal alert, which is cheaper than a silent drop.
#
# Reports; clearing stays a human decision.
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

  # The bound on the work: how many blocks get their buyer's history counted. Everything past it is
  # unscanned, and the report says so rather than presenting its count as the total. Measured 40,000+
  # candidate blocks, so a full pass is deliberately out of reach for one run — this job surfaces the
  # worst of the backlog repeatedly rather than claiming to enumerate it.
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
      candidates = candidate_blocks
      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)

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
    def candidate_blocks
      PlatformBlock.active
                   .where(object_type: BLOCK_TYPE, blocked_by: nil)
                   .where.not(object_value: nil)
                   .order(blocked_at: :asc, id: :asc)
                   .limit(MAX_CANDIDATES_SCANNED + 1)
                   .to_a
    end

    # Downcased email => settled non-free purchase count, for buyers clearing the same bar
    # Purchase::Blockable#buyer_has_clean_payment_history? sets: purchases old enough for a cardholder
    # to have disputed them, none refunded, none charged back. Reading the same constants is what
    # keeps a report of "this block should not be holding them" aligned with the rule that decides
    # whether to write one.
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
        "These buyers have NOT tried recently — that is why the failure-keyed report never named them. " \
          "A line here is not proof the block is stale: a velocity rule writes `blocked_by` nil too, so " \
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
        "#{Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY}+ settled purchases who has not tried to check out recently."
    end
end
