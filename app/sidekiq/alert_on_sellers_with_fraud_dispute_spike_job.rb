# frozen_string_literal: true

# Reports sellers whose recent sales are drawing disputes and early fraud warnings in bulk, so a
# person can look at the account while it is still selling. The scan lives in
# Radar::SellerFraudSignalScanService; this job only reports and changes nothing about the accounts.
class AlertOnSellersWithFraudDisputeSpikeJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    scan = Radar::SellerFraudSignalScanService.call

    return if scan[:sellers].empty?

    InternalNotificationWorker.perform_async("risk", "Sellers drawing fraud disputes in bulk", message_for(scan))
  end

  private
    def message_for(scan)
      sellers = scan[:sellers]
      lines = sellers.first(MAX_REPORTED).map { |seller| line_for(seller) }
      omitted = sellers.size - lines.size

      [
        headline(sellers.size, scan[:truncated]),
        ("The scan stopped at #{Radar::SellerFraudSignalScanService::MAX_CANDIDATES} sellers with a recent dispute or early fraud warning, so others in this window are not counted here." if scan[:truncated]),
        "",
        *lines,
        ("…and #{omitted} more." if omitted.positive?),
        "",
        "Each of these sold at least #{Radar::SellerFraudSignalScanService::MIN_SUCCESSFUL_SALES} times in the last " \
          "#{(Radar::SellerFraudSignalScanService::LOOKBACK_PERIOD / 1.day).round} days with at least " \
          "#{(Radar::SellerFraudSignalScanService::FRAUD_SIGNAL_SHARE_THRESHOLD * 100).round}% of those sales disputed " \
          "or carrying an early fraud warning.",
        "Nothing has been done to these accounts. Suspension and payout holds stay manual until these thresholds have " \
          "been replayed against accounts already known to be fraudulent.",
      ].compact.join("\n")
    end

    def line_for(seller)
      fraudulent = seller[:fraudulent_disputes].positive? ? " (#{seller[:fraudulent_disputes]} fraudulent)" : ""

      "• #{seller[:email]} — #{seller[:signals]} of #{seller[:successful_sales]} sales disputed or warned " \
        "(#{(seller[:share] * 100).round(1)}%): #{count_of(seller[:disputes], "dispute")}#{fraudulent}, " \
        "#{count_of(seller[:efws], "early fraud warning")}, account created #{seller[:created_at]&.to_date}"
    end

    def headline(count, truncated)
      "#{truncated ? "At least " : ""}#{count_of(count, "seller")} " \
        "#{count == 1 ? "is" : "are"} drawing fraud disputes or early fraud warnings in bulk."
    end

    def count_of(count, noun)
      "#{count} #{noun.pluralize(count)}"
    end
end
