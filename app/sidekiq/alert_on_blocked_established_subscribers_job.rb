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

    InternalNotificationWorker.perform_async("risk", "Blocked established subscribers", message_for(scan))
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

    # Distinct subscriptions, most recent failure first, one over the candidate budget so that
    # exhausting it is distinguishable from a window holding exactly that many.
    def candidate_subscription_ids
      Purchase.failed
              .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago..)
              .where.not(subscription_id: nil)
              .group(:subscription_id)
              .order(Arel.sql("MAX(purchases.created_at) DESC"))
              .limit(MAX_CANDIDATES_SCANNED + 1)
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

      # Each lookup mirrors the check that declined this renewal, and the two checks do NOT agree on
      # type scope. Purchase::Risk#check_for_past_blocked_guids goes through #past_blocked_object,
      # which matches object_value alone — a guid string stored under any type declines the renewal,
      # so scoping to :browser_guid here would find nothing and drop the subscriber from the report
      # entirely. The domain check runs through AttributeBlockable, which does scope to
      # :email_domain, so that lookup stays scoped.
      #
      # The domain lookup also resolves by candidate order rather than by date, because
      # blocked_by_email_domain_if_fraudulent_transaction? short-circuits on the first of the four
      # domains that is blocked; that row holds this renewal even when another candidate carries an
      # older block.
      guid_dates = guids.any? ? normalized_block_dates(guids) : {}
      all_domains = domains_by_purchase.values.flatten.uniq
      domain_dates = all_domains.any? ? normalized_block_dates(all_domains, object_type: PlatformBlock::TYPES[:email_domain]) : {}

      dates = {}
      guid_purchases.each { |purchase| dates[purchase.id] = guid_dates[purchase.browser_guid&.downcase] }
      domain_purchases.each do |purchase|
        declining_domain = domains_by_purchase[purchase].find { |domain| domain_dates.key?(domain.downcase) }
        dates[purchase.id] = domain_dates[declining_domain.downcase] if declining_domain
      end
      dates
    end

    # Keyed on the downcased value, because the lookup is case-insensitive but the hash is not: the
    # column collates utf8mb4_unicode_ci, so a row stored as `Example.COM` enforces against
    # `buyer@example.com` yet comes back under its own casing and would miss a case-sensitive key.
    def normalized_block_dates(values, object_type: nil)
      scope = PlatformBlock.active.where(object_value: values)
      scope = scope.where(object_type:) if object_type
      scope.group(:object_value)
           .minimum(:blocked_at)
           .each_with_object({}) do |(value, blocked_at), dates|
             key = value.downcase
             dates[key] = blocked_at if dates[key].nil? || blocked_at < dates[key]
           end
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
