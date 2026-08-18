# frozen_string_literal: true

# Reports established subscribers who are currently stranded behind a platform block their renewals
# keep failing against (gumroad-private#1480).
#
# PlatformBlock rows on a browser guid, an email or a domain have no expiry, so a block outlives
# whatever rule justified it. A failed renewal looks like a card problem to the subscriber, so this
# only reaches us if they write in.
#
# Reports; clearing stays a human decision.
class AlertOnBlockedEstablishedSubscribersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # A block is not a retryable error (PurchaseErrorCode.is_error_retryable? covers insufficient
  # funds only), so a blocked subscriber fails once and then goes quiet until their next billing
  # date. Eligibility is the block being active now; this window only finds candidates, and has to
  # be wide enough to still find them weeks after their single failed attempt.
  FAILURE_LOOKBACK = 30.days

  # The decline codes an in-app PlatformBlock check can set on a RENEWAL. Purchase::Risk's IP check
  # returns early on recurring charges, and the BLOCKED_CUSTOMER_* codes are a seller blocking their
  # own buyer — a decision, not staleness.
  #
  # ⚠️ This is the in-app set only. Whole-address `email` and `charge_processor_fingerprint` blocks
  # are enforced at Stripe via Radar value lists (Radar::ValueListSyncService), never by
  # check_for_fraud, so a renewal they stop carries no distinguishing code — measured: 0 of 6,736
  # failed renewals in 30 days had a code that could identify one. Those two types are out of reach
  # from failure rows and need their own detector; a quiet report here is NOT evidence that nobody
  # is stranded behind them. See gumroad-private#1480.
  BLOCK_ERROR_CODES = [
    PurchaseErrorCode::BLOCKED_BROWSER_GUID,
    PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN,
  ].freeze

  # A subscriber this far into a subscription is not a card tester. Same figure #1480 measured its
  # population with.
  MIN_SUCCESSFUL_CHARGES = 6

  # Report at most this many, still-renewing memberships first. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many subscriptions with a blocked renewal get their charge history
  # counted. Everything past it is unscanned, and the report says so rather than presenting its
  # count as the total. Nothing is dropped inside the window — candidates arrive newest-failure
  # first, so ranking a prefix of them is not ranking the window, and the rows the report exists to
  # surface (memberships still renewing, whatever their failure date) can sit anywhere in it.
  # Measured headroom: 157 candidates over 30 days, 242 in the worst 30-day stretch of the last 90.
  MAX_CANDIDATES_SCANNED = 10_000

  # Candidates are counted in batches to keep each grouped query's IN list bounded.
  CHARGE_COUNT_BATCH = 500

  def perform
    scan = scan_for_stranded_subscriptions
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:stranded].empty? && !scan[:truncated]

    # agent_reports, not risk: the stranded-buyer recovery lane works these candidates
    # autonomously, so humans only see its escalations (gumroad-private#2106).
    InternalNotificationWorker.perform_async("agent_reports", "Blocked established subscribers", message_for(scan))
  end

  private
    # One entry per subscription whose holder has real payment history and whose renewal-declining
    # block is still active, in the report's own ranking. `truncated` means the candidate window was
    # cut short, so the counts are floors.
    #
    # The whole window is walked before anything is ranked. Candidates arrive newest-failure-first,
    # so ranking a prefix of them is not ranking the window: a still-renewing membership whose
    # renewal failed weeks ago sits behind any number of newer terminated ones, and it is exactly
    # the row the report exists to surface.
    def scan_for_stranded_subscriptions
      candidates = candidate_subscription_ids
      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)

      stranded = []
      candidates.each_slice(CHARGE_COUNT_BATCH) do |batch|
        charge_counts = established_charge_counts(batch)
        next if charge_counts.empty?

        failures = latest_block_failures(charge_counts.keys)
        failures = reject_recovered(failures)
        next if failures.empty?

        block_dates = active_block_dates(failures)
        live_subscription_ids = live_subscription_ids_among(charge_counts.keys)

        failures.each do |purchase|
          blocked_at = block_dates[purchase.id]
          next if blocked_at.nil?

          stranded << {
            subscription_id: purchase.subscription_id,
            successful_charges: charge_counts[purchase.subscription_id],
            blocked_at:,
            failed_at: purchase.created_at,
            live: live_subscription_ids.include?(purchase.subscription_id),
          }
        end
      end

      { stranded: report_order(stranded), truncated: }
    end

    # Subscription id => successful charge count, for the given candidates clearing
    # MIN_SUCCESSFUL_CHARGES.
    def established_charge_counts(subscription_ids)
      Purchase.successful
              .where(subscription_id: subscription_ids)
              .group(:subscription_id)
              .count
              .select { |_, count| count >= MIN_SUCCESSFUL_CHARGES }
    end

    # Renewals only, which is what the report claims is failing. Both queries below select from
    # here so they cannot disagree about what a renewal is.
    #
    # `recurring_charge` alone is not that predicate. It excludes the original subscription purchase
    # — a plan change builds one, carries a subscription_id and runs the same fraud checks, so
    # without it every plan-change block on a long-tenured member became a false "blocked from
    # renewing" row. But it still admits the gift-receiver purchase, which is the OPENING purchase
    # of a gifted membership rather than a renewal (Subscription counts it alongside the original
    # for inventory, and Purchase#is_recurring_subscription_charge excludes both). Excluding it here
    # makes this scope that predicate.
    def blocked_renewal_failures
      Purchase.failed
              .recurring_charge
              .not_is_gift_receiver_purchase
              .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago..)
    end

    # Distinct subscriptions, most recent failure first, one over the candidate budget so that
    # exhausting it is distinguishable from a window holding exactly that many.
    def candidate_subscription_ids
      blocked_renewal_failures
        .group(:subscription_id)
        .order(Arel.sql("MAX(purchases.created_at) DESC"))
        .limit(MAX_CANDIDATES_SCANNED + 1)
        .pluck(:subscription_id)
    end

    # The newest blocked renewal per subscription — its error code and identity attributes say which
    # block did the declining. The returned set is unordered on purpose: message_for decides the
    # report's order, so a second ordering here would only mask whether that one works.
    #
    # Newest is by created_at, NOT by MAX(id): a backfill, an import or a retry that preserves
    # timestamps can give an older failure the higher id, and then the report would quote that
    # older row's guid/domain, block date and "last tried" date while claiming to describe the
    # newest renewal. id descending only breaks same-timestamp ties, so the pick is deterministic.
    def latest_block_failures(subscription_ids)
      return [] if subscription_ids.empty?

      newest_per_subscription = blocked_renewal_failures
                                  .where(subscription_id: subscription_ids)
                                  .order(created_at: :desc, id: :desc)
                                  .pluck(:subscription_id, :id)
                                  .each_with_object({}) { |(subscription_id, id), newest| newest[subscription_id] ||= id }

      Purchase.where(id: newest_per_subscription.values)
              .includes(:purchaser, :gift_given, :gift_received)
              .to_a
    end

    # Drops subscriptions whose newest successful renewal postdates their newest blocked failure:
    # eligibility is "stranded now", and a failure row alone cannot say that. A block re-written
    # after a charge got through is a different event from the one that failed.
    #
    # A successful UPGRADE charge counts as recovery and is deliberately not excluded. It settles
    # the overdue period, so the subscriber is not stranded at report time — but it carries the
    # buyer's live browser_guid while renewals keep copying the original purchase's, so a
    # guid-blocked subscriber who self-rescues this way reappears only after the next cycle fails.
    # Ties go to the report: a same-second pair is an ambiguous ordering, and a human reading a
    # false positive beats a silent drop.
    def reject_recovered(failures)
      return failures if failures.empty?

      newest_success = Purchase.successful
                               .recurring_charge
                               .not_is_gift_receiver_purchase
                               .where(subscription_id: failures.map(&:subscription_id))
                               .group(:subscription_id)
                               .maximum(:created_at)

      failures.reject do |purchase|
        renewed_at = newest_success[purchase.subscription_id]
        renewed_at.present? && renewed_at > purchase.created_at
      end
    end

    # Purchase id => date its declining block was written, absent when no block is active any more.
    # Shared with AlertOnBlockedEstablishedBuyersJob so the two reports cannot disagree about
    # whether someone is still blocked.
    def active_block_dates(failures)
      DecliningPlatformBlocks.new(failures).call.transform_values(&:blocked_at)
    end

    def live_subscription_ids_among(subscription_ids)
      return Set.new if subscription_ids.empty?

      # Subscription.active is the scope behind #alive?, minus the pending-cancellation nuance that
      # does not matter here: a pending-cancel membership can still be saved by unblocking.
      Set.new(Subscription.where(id: subscription_ids).active.pluck(:id))
    end

    def message_for(scan)
      stranded = scan[:stranded]
      lines = stranded.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stranded.size - lines.size
      live_count = stranded.count { |entry| entry[:live] }

      [
        headline(stranded.size, live_count, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} subscriptions with a blocked renewal, so others in this window are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the renewal by years. Review with `Onetime::ClearMistakenBuyerBlocks` or unblock individually; see gumroad-private#1480.",
      ].compact.join("\n")
    end

    # A block outlives the membership it broke: UnsubscribeAndFailWorker terminates a subscription
    # ~5 days after the failed renewal, so most entries name a membership that is already dead and
    # that clearing the block will not bring back. Sorting the reachable ones first keeps the
    # actionable window at the top instead of buried under months of aftermath.
    def report_order(stranded)
      stranded.sort_by { |entry| [entry[:live] ? 0 : 1, -entry[:failed_at].to_i] }
    end

    def line_for(entry)
      state = entry[:live] ? "still renewing" : "membership already terminated"
      new_marker = entry[:failed_at] >= 24.hours.ago ? "NEW — " : ""
      "• #{new_marker}subscription #{entry[:subscription_id]} — #{entry[:successful_charges]} successful charges, " \
        "blocked since #{entry[:blocked_at].to_date}, last tried #{entry[:failed_at].to_date} (#{state})"
    end

    def headline(count, live_count, truncated)
      return "No subscription qualified on the scanned page, but the scan was truncated, so this is not evidence that nobody is stranded." if count.zero?

      "#{truncated ? "At least " : ""}#{count} subscription#{"s" if count != 1} with #{MIN_SUCCESSFUL_CHARGES}+ successful charges " \
        "#{count == 1 ? "is" : "are"} blocked from renewing by an active platform block. #{live_count} of them can still be saved; " \
        "the rest have already been terminated."
    end
end
