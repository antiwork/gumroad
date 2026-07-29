# frozen_string_literal: true

# Reports subscribers with long payment histories whose renewals are failing because we
# platform-blocked them (gumroad-private#1480).
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

  # Wider than the daily interval on purpose: the window is anchored to execution time on a
  # low-priority queue, so an exact 24h would drop failures whenever a run starts later than the
  # one before it. Overlap costs a repeated line; a gap loses a stranded subscriber.
  LOOKBACK = 25.hours

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

  # Report at most this many, newest first. The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    affected = affected_subscriptions
    return if affected.empty?

    InternalNotificationWorker.perform_async("risk", "Blocked established subscribers", message_for(affected))
  end

  private
    # One entry per subscription whose renewal failed on a platform block in the window and whose
    # holder has real payment history behind them, newest failure first.
    def affected_subscriptions
      failures = Purchase.failed
                         .where(error_code: BLOCK_ERROR_CODES, created_at: LOOKBACK.ago..)
                         .where.not(subscription_id: nil)
                         .order(created_at: :desc)
                         .limit(MAX_FAILURES_SCANNED)
                         .pluck(:subscription_id, :email, :browser_guid)
                         .uniq { |subscription_id, _, _| subscription_id }

      charge_counts = Purchase.successful
                              .where(subscription_id: failures.map(&:first))
                              .group(:subscription_id)
                              .count

      failures.filter_map do |subscription_id, email, browser_guid|
        successful_charges = charge_counts[subscription_id].to_i
        next if successful_charges < MIN_SUCCESSFUL_CHARGES

        { subscription_id:, successful_charges:, email:, browser_guid: }
      end
    end

    # A day's blocked renewals, with headroom for a rule regression writing blocks in bulk — which
    # is the case this alert most needs to survive rather than time out on.
    MAX_FAILURES_SCANNED = 2_000
    private_constant :MAX_FAILURES_SCANNED

    # When the block was written is the useful part: it is routinely years before the renewal it is
    # now failing, which is what tells a reader this is staleness rather than a buyer who just did
    # something wrong.
    #
    # Matched as (type, value) pairs, where the enforcement path (Purchase::Risk#past_blocked_object)
    # matches on value alone, so a block of an unexpected type reads as "unknown" here rather than
    # being reported with a date that belongs to a different row.
    def blocked_since(email, browser_guid)
      pairs = [
        [PlatformBlock::TYPES[:browser_guid], browser_guid],
        [PlatformBlock::TYPES[:email], email],
        [PlatformBlock::TYPES[:email_domain], email.presence && Mail::Address.new(email).domain],
      ].reject { |_, value| value.blank? }
      return if pairs.empty?

      PlatformBlock.active
                   .where(pairs.map { "(object_type = ? AND object_value = ?)" }.join(" OR "), *pairs.flatten)
                   .minimum(:blocked_at)
    rescue Mail::Field::IncompleteParseError
      nil
    end

    def message_for(affected)
      lines = affected.first(MAX_REPORTED).map do |entry|
        since = blocked_since(entry[:email], entry[:browser_guid])
        "• subscription #{entry[:subscription_id]} — #{entry[:successful_charges]} successful charges, blocked since #{since ? since.to_date : "unknown"}"
      end
      omitted = affected.size - lines.size

      [
        "#{affected.size} subscription#{"s" if affected.size != 1} with #{MIN_SUCCESSFUL_CHARGES}+ successful charges failed to renew in the last #{LOOKBACK.inspect} because the subscriber is platform-blocked.",
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the renewal by years. Review with `Onetime::ClearMistakenBuyerBlocks` or unblock individually; see gumroad-private#1480.",
      ].compact.join("\n")
    end
end
