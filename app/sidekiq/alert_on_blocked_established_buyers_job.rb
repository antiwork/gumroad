# frozen_string_literal: true

# Reports buyers with real payment history who are currently stranded behind a platform block their
# checkouts keep failing against (gumroad-private#1640).
#
# AlertOnBlockedEstablishedSubscribersJob covers the same staleness on RENEWALS. It cannot see the
# buyer this job exists for: it selects subscriptions, and a stranded buyer's failing purchase is
# usually an ordinary one-off checkout. Measured over 7 days of these failures, 76% of the clean
# history buyers behind them had no recurring charge the subscriber report could have keyed on.
#
# The scan itself lives in Risk::StrandedBuyerScanService, shared with the admin API so the alert
# and the CLI cannot disagree about who is stranded. Reports; clearing goes through
# Risk::StrandedBuyerRecoveryService or a human.
class AlertOnBlockedEstablishedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    scan = Risk::StrandedBuyerScanService.call

    # With the recovery flag live, RecoverStrandedBuyersJob scans this same population on a
    # schedule and emits its own outcomes report, so a per-buyer alert listing the same people is
    # duplicate noise. Suppress only that per-buyer case: the truncation-with-nothing-qualifying
    # line below still goes out, because the recovery job returns early on an empty scan and never
    # emits it (gumroad-private#2106).
    return if Feature.active?(:auto_recover_stranded_buyers) && scan[:stranded].any?

    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:stranded].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("risk", "Blocked established buyers", message_for(scan))
  end

  private
    def message_for(scan)
      stranded = scan[:stranded]
      lines = stranded.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stranded.size - lines.size

      [
        headline(stranded.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{Risk::StrandedBuyerScanService::MAX_CANDIDATES_SCANNED} buyers with a blocked checkout, so others in this window are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "Platform blocks do not expire, so these can predate the checkout by years — but a recent " \
          "`blocked since` date usually means a velocity rule wrote the row for cause, not that a " \
          "rule outlived itself. `Risk::StrandedBuyerRecoveryService` encodes those checks: dry-run " \
          "it per buyer before clearing anything by hand; see gumroad-private#1640.",
      ].compact.join("\n")
    end

    def line_for(entry)
      new_marker = entry[:failed_at] >= 24.hours.ago ? "NEW — " : ""
      attempts = entry[:attempts] > 1 ? ", #{entry[:attempts]} attempts" : ""
      # The block's TYPE decides what clearing it costs: an email_domain row holds every buyer on
      # that domain, so a reader acting on this line has to know they are not unblocking one person.
      "• #{new_marker}#{entry[:email]} — #{entry[:settled_purchases]} settled purchases, " \
        "blocked by #{entry[:block_type]} since #{entry[:blocked_at].to_date}, " \
        "last tried #{entry[:failed_at].to_date}#{attempts}"
    end

    def headline(count, truncated)
      return "No buyer qualified on the scanned page, but the scan was truncated, so this is not evidence that nobody is stranded." if count.zero?

      "#{truncated ? "At least " : ""}#{count} buyer#{"s" if count != 1} with " \
        "#{Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY}+ settled purchases " \
        "#{count == 1 ? "is" : "are"} blocked from checking out by an active platform block."
    end
end
