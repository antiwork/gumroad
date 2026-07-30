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

  # Report at most this many, newest failure first. The alert exists to be read.
  MAX_REPORTED = 25

  # Counted in distinct subscriptions, not failure rows, so one subscriber's retries cannot fill the
  # cap and hide everybody behind them. Measured headroom: 157 candidates over 30 days, and 242 rows
  # in the worst 30-day stretch of the last 90 days. The cap is for a rule regression writing blocks
  # in bulk, and hitting it makes the report say so rather than reading as the whole incident.
  MAX_SUBSCRIPTIONS_SCANNED = 2_000

  def perform
    scan = scan_for_stranded_subscriptions
    # Truncation with nothing qualifying still has to go out: it means the cap, not the platform,
    # decided the report was empty.
    return if scan[:stranded].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Blocked established subscribers", message_for(scan))
  end

  private
    # One entry per subscription whose holder has real payment history and whose renewal-declining
    # block is still active, newest failure first. `truncated` means the counts below are floors.
    def scan_for_stranded_subscriptions
      candidates = candidate_subscription_ids
      truncated = candidates.size > MAX_SUBSCRIPTIONS_SCANNED
      candidates = candidates.first(MAX_SUBSCRIPTIONS_SCANNED)

      charge_counts = Purchase.successful
                              .where(subscription_id: candidates)
                              .group(:subscription_id)
                              .count
                              .select { |_, count| count >= MIN_SUCCESSFUL_CHARGES }

      failures = latest_block_failures(charge_counts.keys)
      block_dates = active_block_dates(failures)
      live_subscription_ids = live_subscription_ids_among(charge_counts.keys)

      stranded = failures.filter_map do |purchase|
        blocked_at = block_dates[purchase.id]
        next if blocked_at.nil?

        {
          subscription_id: purchase.subscription_id,
          successful_charges: charge_counts[purchase.subscription_id],
          blocked_at:,
          failed_at: purchase.created_at,
          live: live_subscription_ids.include?(purchase.subscription_id),
        }
      end

      { stranded:, truncated: }
    end

    # Distinct subscriptions, most recent failure first, one over the cap so that hitting it is
    # distinguishable from a window holding exactly the cap.
    def candidate_subscription_ids
      Purchase.failed
              .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago..)
              .where.not(subscription_id: nil)
              .group(:subscription_id)
              .order(Arel.sql("MAX(purchases.created_at) DESC"))
              .limit(MAX_SUBSCRIPTIONS_SCANNED + 1)
              .pluck(:subscription_id)
    end

    # The newest blocked renewal per subscription — its error code and identity attributes say which
    # block did the declining. Unordered on purpose: message_for decides the report's order, so a
    # second ordering here would only mask whether that one works.
    def latest_block_failures(subscription_ids)
      return [] if subscription_ids.empty?

      newest_per_subscription = Purchase.failed
                                        .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago.., subscription_id: subscription_ids)
                                        .group(:subscription_id)
                                        .maximum(:id)

      Purchase.where(id: newest_per_subscription.values)
              .includes(:purchaser, :gift_given, :gift_received)
              .to_a
    end

    # Purchase id => date its declining block was written, absent when no block is active any more.
    # Two grouped queries for the whole set rather than one per entry.
    def active_block_dates(failures)
      guid_purchases, domain_purchases = failures.partition { |purchase| purchase.error_code == PurchaseErrorCode::BLOCKED_BROWSER_GUID }

      guids = guid_purchases.filter_map { |purchase| purchase.browser_guid.presence }.uniq
      domains_by_purchase = domain_purchases.index_with { |purchase| blocked_domain_candidates(purchase) }

      # Scoped to the check that declined this renewal, mirroring Purchase::Risk: the domain check
      # runs first and short-circuits, and the guid check matches on object_value alone (so this
      # does too). Widening to every block the subscriber has would date a recent block from an
      # unrelated older one and send cleanup at the wrong row.
      guid_dates = guids.any? ? PlatformBlock.active.where(object_value: guids).group(:object_value).minimum(:blocked_at) : {}
      all_domains = domains_by_purchase.values.flatten.uniq
      domain_dates = all_domains.any? ? PlatformBlock.active.where(object_type: PlatformBlock::TYPES[:email_domain], object_value: all_domains).group(:object_value).minimum(:blocked_at) : {}

      dates = {}
      guid_purchases.each { |purchase| dates[purchase.id] = guid_dates[purchase.browser_guid] }
      domain_purchases.each do |purchase|
        dates[purchase.id] = domains_by_purchase[purchase].filter_map { |domain| domain_dates[domain] }.min
      end
      dates
    end

    # The same four domains Purchase::Blockable#blocked_by_email_domain_if_fraudulent_transaction?
    # reads. Reading fewer would drop a subscriber blocked on, say, their account's domain — and
    # dropping them now means never reporting them.
    def blocked_domain_candidates(purchase)
      [:email_domain, :paypal_email_domain, :gifter_email_domain, :purchaser_email_domain].filter_map do |domain_method|
        purchase.send(domain_method)
      rescue Mail::Field::IncompleteParseError
        nil
      end.uniq
    end

    def live_subscription_ids_among(subscription_ids)
      return Set.new if subscription_ids.empty?

      # Subscription.active is the scope behind #alive?, minus the pending-cancellation nuance that
      # does not matter here: a pending-cancel membership can still be saved by unblocking.
      Set.new(Subscription.where(id: subscription_ids).active.pluck(:id))
    end

    def message_for(scan)
      stranded = scan[:stranded]
      # A block outlives the membership it broke: UnsubscribeAndFailWorker terminates a subscription
      # ~5 days after the failed renewal, so most entries name a membership that is already dead and
      # that clearing the block will not bring back. Sorting the reachable ones first keeps the
      # actionable window at the top instead of buried under months of aftermath.
      ordered = stranded.sort_by { |entry| [entry[:live] ? 0 : 1, -entry[:failed_at].to_i] }
      lines = ordered.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stranded.size - lines.size
      live_count = stranded.count { |entry| entry[:live] }

      [
        headline(stranded.size, live_count, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at the newest #{MAX_SUBSCRIPTIONS_SCANNED} subscriptions with a blocked renewal, so others in this window are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the renewal by years. Review with `Onetime::ClearMistakenBuyerBlocks` or unblock individually; see gumroad-private#1480.",
      ].compact.join("\n")
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
