# frozen_string_literal: true

# Reports buyers with real payment history who are currently stranded behind a platform block their
# checkouts keep failing against (gumroad-private#1640).
#
# AlertOnBlockedEstablishedSubscribersJob covers the same staleness on RENEWALS. It cannot see the
# buyer this job exists for: it selects subscriptions, and a stranded buyer's failing purchase is
# usually an ordinary one-off checkout. Measured over 7 days of these failures, 76% of the clean
# history buyers behind them had no recurring charge the subscriber report could have keyed on.
#
# Reports; clearing stays a human decision.
class AlertOnBlockedEstablishedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # A block is not a retryable error, so a blocked buyer fails, gives up, and is silent from then
  # on. Eligibility is the block being active now; this window only decides whose failures we look
  # at, and a one-off buyer never generates another row, so anyone who falls out of it is invisible
  # to this report forever. Matches the subscriber job, which has the easier job of it: a
  # subscription keeps retrying itself on every billing date.
  FAILURE_LOOKBACK = 30.days

  # The decline codes an in-app PlatformBlock check can set on a checkout.
  #
  # ⚠️ This is the in-app set only. Whole-address `email` and `charge_processor_fingerprint` blocks
  # are enforced at Stripe via Radar value lists (Radar::ValueListSyncService), never by
  # check_for_fraud, so a checkout they stop carries no distinguishing code. Those two types are out
  # of reach from failure rows and need their own detector; a quiet report here is NOT evidence that
  # nobody is stranded behind them. See gumroad-private#1480.
  BLOCK_ERROR_CODES = [
    PurchaseErrorCode::BLOCKED_BROWSER_GUID,
    PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN,
  ].freeze

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many buyers with a blocked checkout get their purchase history
  # counted. Everything past it is unscanned, and the report says so rather than presenting its
  # count as the total. Nothing is dropped inside the window — candidates arrive newest-failure
  # first, so ranking a prefix of them is not ranking the window. Measured headroom: 1,453 distinct
  # emails over the 7-day window.
  MAX_CANDIDATES_SCANNED = 20_000

  # Candidates are counted in batches to keep each grouped query's IN list bounded.
  HISTORY_COUNT_BATCH = 500

  def perform
    scan = scan_for_stranded_buyers
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:stranded].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Blocked established buyers", message_for(scan))
  end

  private
    # One entry per buyer with settled payment history whose declining block is still active, in the
    # report's own ranking. `truncated` means the candidate window was cut short, so the counts are
    # floors.
    def scan_for_stranded_buyers
      candidates = candidate_emails
      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)

      stranded = []
      candidates.each_slice(HISTORY_COUNT_BATCH) do |batch|
        settled = settled_purchase_counts(batch)
        next if settled.empty?

        settled = reject_disputed(settled)
        next if settled.empty?

        failures, attempts = latest_block_failures(settled.keys)
        failures = reject_recovered(failures)
        next if failures.empty?

        blocks = DecliningPlatformBlocks.new(failures).call

        failures.each do |purchase|
          block = blocks[purchase.id]
          next if block.nil?
          # An admin or chargeback block names who wrote it. That is a decision about this buyer,
          # not a rule that outlived itself, so it is not this report's business — and surfacing it
          # as staleness would invite clearing a block somebody still means.
          #
          # Not airtight: PlatformBlock.add! overwrites blocked_by on every re-block, so a human's
          # row that a velocity rule later re-triggered arrives here as unattended. The velocity
          # rules write blocked_by nil too, which is why the report tells its reader to re-check them
          # rather than presenting a line as proof the block is stale.
          next if block.blocked_by.present?

          stranded << {
            email: purchase.email,
            settled_purchases: settled[purchase.email.downcase],
            blocked_at: block.blocked_at,
            block_type: block.object_type,
            failed_at: purchase.created_at,
            attempts: attempts[purchase.email.downcase],
          }
        end
      end

      { stranded: report_order(stranded), truncated: }
    end

    # Failed checkouts a platform block declined, in the window.
    #
    # Deliberately not scoped to one-off purchases: a renewal blocked on a guid the subscriber
    # report skipped (under its 6-charge floor, or its membership already terminated) is the same
    # stranded person. The subscriber report is the one with the narrow population; overlap between
    # the two is a duplicate line in an internal alert, which is cheaper than a silent drop.
    def blocked_failures
      Purchase.failed.where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago..)
    end

    # Distinct buyer emails, most recent failure first, one over the candidate budget so that
    # exhausting it is distinguishable from a window holding exactly that many.
    #
    # Keyed on email, not on the card fingerprint Purchase::Blockable#buyer_has_clean_payment_history?
    # uses: these blocks are enforced BEFORE the charge processor is called, so the failure row has
    # no fingerprint to key on — measured 0 of 3,414 such failures over 7 days carried one.
    #
    # Email is a weaker identity than a card: anyone can type an established customer's address at a
    # guest checkout, so a line here can pair a fraudster's device block with a stranger's history.
    # That is a report a human must judge, which is why this job only reports.
    def candidate_emails
      blocked_failures
        .where.not(email: nil)
        .group(:email)
        .order(Arel.sql("MAX(purchases.created_at) DESC"))
        .limit(MAX_CANDIDATES_SCANNED + 1)
        .pluck(:email)
    end

    # Downcased email => settled non-free purchase count, for buyers clearing the same bar
    # #buyer_has_clean_payment_history? sets: purchases old enough for a cardholder to have disputed
    # them, none refunded, none charged back. Reading the same constants is what keeps a report of
    # "this block should not be holding them" aligned with the rule that decides whether to write one.
    #
    # Keyed on the downcased address. Purchase#downcase_email only normalizes rows saved since that
    # callback existed — sampling the oldest ids in production, every one of 500 carried uppercase —
    # and the ci collation then hands a mixed-case group back under an arbitrary member's casing.
    # Without normalising both sides, such a buyer's history does not join to their failure row.
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
    #
    # Reversed chargebacks do not count — the dispute resolved in our favour, and the same row is
    # already counted as clean history above via not_chargedback_or_chargedback_reversed. Refunds do
    # not count either: an ordinary remorse refund is customer service, not a fraud signal, and
    # vetoing on one would permanently hide exactly the long-standing buyers this report exists to
    # find. Still a stricter bar than #buyer_has_clean_payment_history?, which never disqualifies a
    # card for a dispute elsewhere: per-email counting needs the veto that per-card counting gets
    # from the card being the thing that was disputed.
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

    # The newest blocked checkout per buyer — its error code and identity attributes say which block
    # did the declining — plus how many times each buyer tried, which is their own measure of how
    # badly they wanted to pay us.
    #
    # Newest is by created_at, NOT by MAX(id): a backfill, an import or a retry that preserves
    # timestamps can give an older failure the higher id, and then the report would quote that older
    # row's guid/domain and dates while claiming to describe the newest attempt. id descending only
    # breaks same-timestamp ties, so the pick is deterministic.
    def latest_block_failures(emails)
      return [[], {}] if emails.empty?

      rows = blocked_failures.where(email: emails)
                             .order(created_at: :desc, id: :desc)
                             .pluck(:email, :id)

      newest_per_email = {}
      attempts = Hash.new(0)
      rows.each do |email, id|
        key = email.downcase
        newest_per_email[key] ||= id
        attempts[key] += 1
      end

      [Purchase.where(id: newest_per_email.values).includes(:purchaser).to_a, attempts]
    end

    # Drops buyers whose newest paid purchase postdates their newest blocked failure: eligibility is
    # "stranded now", and a failure row alone cannot say that. A buyer who paid afterwards either was
    # never fully blocked or already found a way round it. Free purchases do not count — claiming a
    # free download does not prove checkout works for them.
    #
    # Ties go to the report: a same-second pair is an ambiguous ordering, and a human reading a false
    # positive beats a silent drop.
    def reject_recovered(failures)
      return failures if failures.empty?

      newest_success = Purchase.successful.non_free
                               .where(email: failures.map(&:email))
                               .group(:email)
                               .maximum(:created_at)
                               .transform_keys(&:downcase)

      failures.reject do |purchase|
        bought_at = newest_success[purchase.email.downcase]
        bought_at.present? && bought_at > purchase.created_at
      end
    end

    def message_for(scan)
      stranded = scan[:stranded]
      lines = stranded.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stranded.size - lines.size

      [
        headline(stranded.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} buyers with a blocked checkout, so others in this window are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the checkout by years — but a recent " \
          "`blocked since` date usually means a velocity rule wrote the row for cause, not that a " \
          "rule outlived itself. `Onetime::ClearMistakenBuyerBlocks` will not clear most of these: " \
          "it selects on the fraud-related decline codes and rejects guid-only bursts by design. So " \
          "check the velocity rules yourself before unblocking by hand; see gumroad-private#1640.",
      ].compact.join("\n")
    end

    # Most settled purchases first. Unlike the subscriber report there is no membership to save, so
    # what ranks a line is how much history the block is standing in front of — the buyer with
    # hundreds of paid purchases is the one a human should read first.
    def report_order(stranded)
      stranded.sort_by { |entry| [-entry[:settled_purchases], -entry[:failed_at].to_i] }
    end

    def line_for(entry)
      new_marker = entry[:failed_at] >= 24.hours.ago ? "NEW — " : ""
      attempts = entry[:attempts] > 1 ? ", #{entry[:attempts]} attempts" : ""
      # The block's TYPE decides what clearing it costs: an email_domain row holds every buyer on
      # that domain, so a reader acting on this line has to know they are not unblocking one person.
      "• #{new_marker}#{entry[:email]} — #{entry[:settled_purchases]} settled purchases, " \
        "blocked by a #{entry[:block_type]} block since #{entry[:blocked_at].to_date}, " \
        "last tried #{entry[:failed_at].to_date}#{attempts}"
    end

    def headline(count, truncated)
      return "No buyer qualified on the scanned page, but the scan was truncated, so this is not evidence that nobody is stranded." if count.zero?

      "#{truncated ? "At least " : ""}#{count} buyer#{"s" if count != 1} with " \
        "#{Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY}+ settled purchases " \
        "#{count == 1 ? "is" : "are"} blocked from checking out by an active platform block."
    end
end
