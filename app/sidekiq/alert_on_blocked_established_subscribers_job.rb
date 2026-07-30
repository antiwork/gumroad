# frozen_string_literal: true

# Reports subscribers with long payment histories who are currently stranded behind a platform
# block their renewals keep failing against (gumroad-private#1480).
#
# PlatformBlock rows on a browser guid, an email or a domain have no expiry, so a block outlives
# whatever rule justified it — measured after #1480's sweep, 116 established subscriptions were
# still failing against guid blocks dated as far back as 2022. A failed renewal looks like a card
# problem to the subscriber, so this only reaches us if they write in.
#
# Reports; clearing stays a human decision.
class AlertOnBlockedEstablishedSubscribersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # How far back to look for the failed renewal that identifies a candidate. Wide on purpose: a
  # block is not a retryable error (PurchaseErrorCode.is_error_retryable? covers insufficient funds
  # only), so a blocked subscriber produces one failure and then nothing until their next billing
  # date. A window sized to the daily run would report them on day one and call them fixed on day
  # two while the block still stands — which is exactly the case #1480 documented. Eligibility is
  # the block being active NOW, so a subscriber stays reported until someone clears it.
  FAILURE_LOOKBACK = 30.days

  # The decline codes that mean "a PlatformBlock stopped this renewal". Deliberately excludes the
  # BLOCKED_CUSTOMER_* codes: those come from a seller blocking a buyer of their own
  # (BlockedCustomerObject), which is a decision we should not be second-guessing here.
  BLOCK_ERROR_CODES = [
    PurchaseErrorCode::BLOCKED_BROWSER_GUID,
    PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN,
  ].freeze

  # A subscriber this far into a subscription is not a card tester. Same figure #1480 measured its
  # population with, so the alert counts the cohort the issue is about.
  MIN_SUCCESSFUL_CHARGES = 6

  # Report at most this many, newest failure first. The alert exists to be read.
  MAX_REPORTED = 25

  # Cap on distinct subscriptions considered, with headroom for a rule regression writing blocks in
  # bulk — which is the case this alert most needs to survive rather than time out on. The cap
  # counts subscriptions rather than failure rows so that one subscriber's retries cannot fill it
  # and hide everybody else. Hitting it makes the report say so, because a silently truncated count
  # reads as the whole incident.
  MAX_SUBSCRIPTIONS_SCANNED = 2_000

  def perform
    scan = scan_for_stranded_subscriptions
    # Truncation with nothing qualifying still has to go out: it means the cap, not the platform,
    # decided the report was empty.
    return if scan[:stranded].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Blocked established subscribers", message_for(scan))
  end

  private
    # One entry per subscription whose holder has real payment history behind them and whose
    # renewal-declining block is still active, newest failure first. `truncated` says the scan hit
    # its cap, so the counts below are floors rather than the whole window.
    def scan_for_stranded_subscriptions
      candidates = candidate_subscription_ids
      truncated = candidates.size > MAX_SUBSCRIPTIONS_SCANNED
      candidates = candidates.first(MAX_SUBSCRIPTIONS_SCANNED)

      charge_counts = Purchase.successful
                              .where(subscription_id: candidates)
                              .group(:subscription_id)
                              .count
                              .select { |_, count| count >= MIN_SUCCESSFUL_CHARGES }

      stranded = latest_block_failures(charge_counts.keys).filter_map do |purchase|
        blocked_at = active_block_date(purchase)
        next if blocked_at.nil?

        { subscription_id: purchase.subscription_id, successful_charges: charge_counts[purchase.subscription_id], blocked_at: }
      end

      { stranded:, truncated: }
    end

    # Distinct subscriptions, most recent failure first, one over the cap so that hitting it is
    # distinguishable from a window that happened to hold exactly the cap.
    def candidate_subscription_ids
      Purchase.failed
              .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago..)
              .where.not(subscription_id: nil)
              .group(:subscription_id)
              .order(Arel.sql("MAX(purchases.created_at) DESC"))
              .limit(MAX_SUBSCRIPTIONS_SCANNED + 1)
              .pluck(:subscription_id)
    end

    # The newest blocked renewal per subscription, in the same order as the candidate list. Its
    # error code and identity attributes are what say which block did the declining.
    def latest_block_failures(subscription_ids)
      return [] if subscription_ids.empty?

      newest_per_subscription = Purchase.failed
                                        .where(error_code: BLOCK_ERROR_CODES, created_at: FAILURE_LOOKBACK.ago.., subscription_id: subscription_ids)
                                        .group(:subscription_id)
                                        .maximum(:id)

      Purchase.where(id: newest_per_subscription.values)
              .includes(:purchaser, :gift_given, :gift_received)
              .order(created_at: :desc)
    end

    # When the block was written is the useful part: it is routinely years before the renewal it is
    # now failing, which is what tells a reader this is staleness rather than a buyer who just did
    # something wrong. `nil` means no block is active any more, which is the signal that this
    # subscriber is no longer stranded and should not be reported at all.
    #
    # Scoped to the check that actually declined this renewal, mirroring Purchase::Risk: the domain
    # check runs first and short-circuits, so BLOCKED_EMAIL_DOMAIN means one of the four domains
    # that check reads, and BLOCKED_BROWSER_GUID means a row carrying the guid as its value (that
    # check matches on value alone, so this does too). Widening to every block the subscriber has
    # would date a recent block from an unrelated older one and send cleanup at the wrong row.
    def active_block_date(purchase)
      case purchase.error_code
      when PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN
        domains = blocked_domain_candidates(purchase)
        return if domains.empty?
        PlatformBlock.active.where(object_type: PlatformBlock::TYPES[:email_domain], object_value: domains).minimum(:blocked_at)
      when PurchaseErrorCode::BLOCKED_BROWSER_GUID
        return if purchase.browser_guid.blank?
        PlatformBlock.active.where(object_value: purchase.browser_guid).minimum(:blocked_at)
      end
    end

    # The same four domains Purchase::Blockable#blocked_by_email_domain_if_fraudulent_transaction?
    # reads. Reading fewer would drop a subscriber blocked on, say, their account's domain rather
    # than the one on the purchase row — and dropping them now means never reporting them.
    def blocked_domain_candidates(purchase)
      [:email_domain, :paypal_email_domain, :gifter_email_domain, :purchaser_email_domain].filter_map do |domain_method|
        purchase.send(domain_method)
      rescue Mail::Field::IncompleteParseError
        nil
      end.uniq
    end

    def message_for(scan)
      stranded = scan[:stranded]
      lines = stranded.first(MAX_REPORTED).map do |entry|
        "• subscription #{entry[:subscription_id]} — #{entry[:successful_charges]} successful charges, blocked since #{entry[:blocked_at].to_date}"
      end
      omitted = stranded.size - lines.size

      [
        headline(stranded.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at the newest #{MAX_SUBSCRIPTIONS_SCANNED} subscriptions with a blocked renewal, so others in this window are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the renewal by years. Review with `Onetime::ClearMistakenBuyerBlocks` or unblock individually; see gumroad-private#1480.",
      ].compact.join("\n")
    end

    def headline(count, truncated)
      return "No subscription qualified on the scanned page, but the scan was truncated, so this is not evidence that nobody is stranded." if count.zero?

      "#{truncated ? "At least " : ""}#{count} subscription#{"s" if count != 1} with #{MIN_SUCCESSFUL_CHARGES}+ successful charges " \
        "#{count == 1 ? "is" : "are"} still blocked from renewing by an active platform block, after failing to renew in the last #{FAILURE_LOOKBACK.inspect}."
    end
end
