# frozen_string_literal: true

# No other job watches reports that wait in screening for a person.
class AlertOnStuckPiracyReportsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many per group. The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    blocked = PiracyReport.blocked_on_recipient.order(:id).limit(MAX_REPORTED + 1).to_a
    review = PiracyReport.needs_review.order(:id).limit(MAX_REPORTED + 1).to_a
    return if blocked.empty? && review.empty?

    InternalNotificationWorker.perform_async(
      "risk", "Piracy reports waiting in screening",
      [blocked_section(blocked), review_section(review)].compact.join("\n\n")
    )
  end

  private
    def blocked_section(reports)
      return if reports.empty?

      [
        "#{count_phrase(reports)} passed screening but the reported host has no verified contact.",
        *listing(reports),
        "",
        "Each host needs a verified takedown contact added to config/piracy_recipients.yml — check the " \
          "Copyright Office directory (https://dmca.copyright.gov/osp/) or the site's own DMCA page, and " \
          "record it as source_url. After deploying the registry change, submit each report's pass verdict " \
          "and checks again through the admin screening API to prepare the notice and request the seller's signature.",
      ].join("\n")
    end

    def review_section(reports)
      return if reports.empty?

      [
        "#{count_phrase(reports)} could not be decided by the screening agent.",
        *listing(reports),
        "",
        "Read the agent's reasons in each report's screening_checks, open the reported page, and submit pass " \
          "or fail through the admin screening API.",
      ].join("\n")
    end

    def count_phrase(reports)
      total = reports.size
      "#{"At least " if total > MAX_REPORTED}#{total} piracy report#{"s" if total != 1}"
    end

    def listing(reports)
      lines = reports.first(MAX_REPORTED).map do |report|
        "• #{report.external_id} — #{report.url_host} (seller #{report.seller_id}), screened #{report.screened_at.to_date}"
      end
      lines << "Only the first #{MAX_REPORTED} are listed." if reports.size > MAX_REPORTED
      ["", *lines]
    end
end
