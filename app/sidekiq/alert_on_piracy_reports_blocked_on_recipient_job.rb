# frozen_string_literal: true

# No other job watches reports waiting indefinitely for a verified recipient.
class AlertOnPiracyReportsBlockedOnRecipientJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    blocked = PiracyReport.blocked_on_recipient.order(:id).limit(MAX_REPORTED + 1).to_a
    return if blocked.empty?

    truncated = blocked.size > MAX_REPORTED
    InternalNotificationWorker.perform_async(
      "risk", "Piracy reports blocked on a missing recipient",
      message_for(blocked.first(MAX_REPORTED), total: blocked.size, truncated:)
    )
  end

  private
    def message_for(reports, total:, truncated:)
      lines = reports.map do |report|
        "• #{report.external_id} — #{report.url_host} (seller #{report.seller_id}), screened #{report.screened_at.to_date}"
      end

      [
        "#{truncated ? "At least " : ""}#{total} piracy report#{"s" if total != 1} passed screening but the reported host has no verified contact.",
        (truncated ? "Only the first #{MAX_REPORTED} are listed." : nil),
        "",
        *lines,
        "",
        "Each host needs a verified takedown contact added to config/piracy_recipients.yml — check the " \
          "Copyright Office directory (https://dmca.copyright.gov/osp/) or the site's own DMCA page, and " \
          "record it as source_url. After deploying the registry change, submit each report's pass verdict " \
          "and checks again through the admin screening API to prepare the notice and request the seller's signature.",
      ].compact.join("\n")
    end
end
