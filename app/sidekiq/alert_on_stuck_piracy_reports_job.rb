# frozen_string_literal: true

# No other job watches piracy reports that wait for a person.
class AlertOnStuckPiracyReportsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many per group. The alert exists to be read.
  MAX_REPORTED = 25

  def perform
    blocked = PiracyReport.blocked_on_recipient.order(:id).limit(MAX_REPORTED + 1).to_a
    review = PiracyReport.needs_review.order(:id).limit(MAX_REPORTED + 1).to_a
    undelivered = PiracyReport.delivery_failed.or(PiracyReport.delivery_unconfirmed).order(:id).limit(MAX_REPORTED + 1).to_a
    return if blocked.empty? && review.empty? && undelivered.empty?

    InternalNotificationWorker.perform_async(
      "risk", "Piracy reports waiting for a person",
      [blocked_section(blocked), review_section(review), delivery_section(undelivered)].compact.join("\n\n")
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
        "Gumclaw works this queue with its own piracy token: it sends each case, with the agent's reasons and the " \
          "reported page, to the piracy reports owner, then submits their pass or fail through the screening API.",
      ].join("\n")
    end

    def delivery_section(reports)
      return if reports.empty?

      lines = reports.first(MAX_REPORTED).map do |report|
        problem = report.delivery_failed_at ? "bounced" : "no delivery event"
        "• #{report.external_id} — #{report.url_host} (seller #{report.seller_id}), sent #{report.sent_at.to_date}, #{problem}"
      end
      lines << "Only the first #{MAX_REPORTED} are listed." if reports.size > MAX_REPORTED

      [
        "#{count_phrase(reports)} sent a notice that did not reach the host.",
        "",
        *lines,
        "",
        "Check the host's takedown contact. If it changed, update config/piracy_recipients.yml and tell the seller " \
          "through support; the notice is not sent again automatically.",
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
