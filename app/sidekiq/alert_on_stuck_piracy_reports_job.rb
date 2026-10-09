# frozen_string_literal: true

# No other job watches piracy reports that wait for a person.
class AlertOnStuckPiracyReportsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many per group. The alert exists to be read.
  MAX_REPORTED = 25
  # The send job runs every 15 minutes, so a signed report older than this is blocked, not queued.
  UNSENT_GRACE = 1.hour
  # Repeated counter-notices can mean a seller files against licensed or fair uses.
  REPEAT_COUNTER_NOTICES = 2
  REPEAT_COUNTER_NOTICE_WINDOW = 90.days

  def perform
    blocked = PiracyReport.blocked_on_recipient.order(:id).limit(MAX_REPORTED + 1).to_a
    review = PiracyReport.needs_review.order(:id).limit(MAX_REPORTED + 1).to_a
    undelivered = PiracyReport.delivery_failed.or(PiracyReport.delivery_unconfirmed).order(:id).limit(MAX_REPORTED + 1).to_a
    unsent = unsent_signed_reports
    repeat_sellers = repeat_counter_noticed_sellers
    return if blocked.empty? && review.empty? && undelivered.empty? && unsent.empty? && repeat_sellers.empty?

    InternalNotificationWorker.perform_async(
      "risk", "Piracy reports waiting for a person",
      [
        blocked_section(blocked), review_section(review), delivery_section(undelivered), unsent_section(unsent),
        repeat_counter_notice_section(repeat_sellers),
      ].compact.join("\n\n")
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

    # While sending is off, every signed report waits on purpose, so only list them when it is on.
    def unsent_signed_reports
      return [] unless Feature.active?(PiracyReports::SendService::FLAG)

      PiracyReport.where(state: "signed", signed_at: ...UNSENT_GRACE.ago).order(:id).limit(MAX_REPORTED + 1).to_a
    end

    def unsent_section(reports)
      return if reports.empty?

      lines = reports.first(MAX_REPORTED).map do |report|
        reason = PiracyReports::SendService.new(report:).blocking_reason || "no reason recorded; the next send run may pick it up"
        "• #{report.external_id} — #{report.url_host} (seller #{report.seller_id}), signed #{report.signed_at.to_date}: #{reason}"
      end
      lines << "Only the first #{MAX_REPORTED} are listed." if reports.size > MAX_REPORTED

      ["#{count_phrase(reports)} signed but not sent.", "", *lines].join("\n")
    end

    def repeat_counter_noticed_sellers
      PiracyReport.where(counter_notice_received_on: REPEAT_COUNTER_NOTICE_WINDOW.ago.to_date..)
        .group(:seller_id).having("COUNT(*) >= ?", REPEAT_COUNTER_NOTICES).count
    end

    def repeat_counter_notice_section(counts)
      return if counts.empty?

      lines = counts.sort.first(MAX_REPORTED).map { |seller_id, count| "• seller #{seller_id}: #{count} counter-notices" }
      [
        "#{counts.size} seller#{"s" if counts.size != 1} received #{REPEAT_COUNTER_NOTICES} or more counter-notices in #{REPEAT_COUNTER_NOTICE_WINDOW.inspect}.",
        "",
        *lines,
        "",
        "Review their reports. To stop a seller filing, turn off their piracy_reports flag.",
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
