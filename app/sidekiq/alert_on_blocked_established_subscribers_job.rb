# frozen_string_literal: true

# Reports established subscribers whose renewals are failing because we platform-blocked them
# (gumroad-private#1480).
#
# #1480 fixed the rule that caused this — a single "lost card" decline no longer brands the buyer —
# and a one-off sweep cleared the rows it had already written. What it did not change is that a
# PlatformBlock row on a browser_guid, an email or a card has no expiry, so a block written by any
# rule outlives whatever justified it. Measured after that sweep: 116 subscriptions with six or
# more successful renewals were still failing on `blocked_browser_guid`, against guid blocks dated
# as far back as 2022, and not one of them would be written by today's velocity rule if the same
# buyer showed up now.
#
# Nobody sees that. A renewal failing on a block looks to the subscriber like a card problem, and
# it reaches us only if they write in — of the three cases in #1480, one did, and one had already
# churned. So this job is the missing feedback loop rather than an enforcement change: it reports,
# and clearing stays a human decision.
class AlertOnBlockedEstablishedSubscribersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  LOOKBACK = 1.day

  # A subscriber this far into a subscription is not a card tester. Deliberately the same figure
  # #1480 measured its population with, so the alert counts the cohort the issue is about.
  MIN_SUCCESSFUL_RENEWALS = 6

  # Report at most this many, newest first. The alert exists to be read; a list nobody finishes is
  # the same as no alert.
  MAX_REPORTED = 25

  def perform
    affected = affected_subscriptions
    return if affected.empty?

    InternalNotificationWorker.perform_async(
      "risk",
      "Blocked established subscribers",
      message_for(affected),
      "yellow"
    )
  end

  private
    # One entry per subscription whose renewal failed on a platform block in the window and whose
    # holder has real payment history behind them.
    def affected_subscriptions
      Purchase.failed
              .where(error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID, created_at: LOOKBACK.ago..)
              .where.not(subscription_id: nil)
              .order(created_at: :desc)
              .pluck(:subscription_id, :email, :browser_guid)
              .uniq { |subscription_id, _, _| subscription_id }
              .filter_map { |subscription_id, email, browser_guid| entry_for(subscription_id, email, browser_guid) }
    end

    def entry_for(subscription_id, email, browser_guid)
      successful_renewals = Purchase.successful.where(subscription_id:).count
      return if successful_renewals < MIN_SUCCESSFUL_RENEWALS

      {
        subscription_id:,
        successful_renewals:,
        # The date the block was written is the useful part: it is routinely years before the
        # renewal it is now failing, which is what tells a reader this is staleness rather than a
        # buyer who just did something wrong.
        blocked_since: blocked_since(email, browser_guid),
      }
    end

    def blocked_since(email, browser_guid)
      pairs = [
        [PlatformBlock::TYPES[:browser_guid], browser_guid],
        [PlatformBlock::TYPES[:email], email],
      ].reject { |_, value| value.blank? }
      return if pairs.empty?

      PlatformBlock.active
                   .where(pairs.map { "(object_type = ? AND object_value = ?)" }.join(" OR "), *pairs.flatten)
                   .minimum(:blocked_at)
    end

    def message_for(affected)
      lines = affected.first(MAX_REPORTED).map do |entry|
        since = entry[:blocked_since] ? entry[:blocked_since].to_date.to_s : "unknown"
        "• subscription #{entry[:subscription_id]} — #{entry[:successful_renewals]} successful renewals, blocked since #{since}"
      end
      omitted = affected.size - lines.size

      [
        "#{affected.size} subscription#{"s" if affected.size != 1} with #{MIN_SUCCESSFUL_RENEWALS}+ successful renewals failed to renew in the last #{LOOKBACK.inspect} because the subscriber is platform-blocked.",
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the renewal by years. Review with `Onetime::ClearMistakenBuyerBlocks` or unblock individually; see gumroad-private#1480.",
      ].compact.join("\n")
    end
end
