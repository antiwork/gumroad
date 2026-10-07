# frozen_string_literal: true

# Reports piracy reports the screening agent approved but the registry cannot route: the reported
# host has no entry in config/piracy_recipients.yml, so the report stays in `screening` forever.
#
# Nothing else watches that queue, so the first real creator report parks silently and no notice
# ever goes out. The alert exists to be read by whoever owns the registry: each listed host needs
# a verified takedown contact added before the report can move on.
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
          "record it as source_url. Until then the report stays in `screening` and no notice is sent.",
      ].compact.join("\n")
    end
end
