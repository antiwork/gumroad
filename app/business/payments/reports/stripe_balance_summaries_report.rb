# frozen_string_literal: true

# Builds the month-end Stripe balance summary packet for every Antiwork Stripe account
# (Gumroad, Flexile, Helper, Iffy). For each account it pulls three Stripe Reporting API
# reports for the given month — balance summary, balance change from activity, and
# payouts — and merges them into a single CSV that mirrors the Stripe dashboard's
# Balance page layout. The CSVs are emailed to finance by
# SendStripeBalanceSummariesReportJob as inputs to the monthly close.
#
# Gumroad settles in dozens of currencies, so its reports are pulled with a USD filter —
# an unfiltered pull adds a starting/ending balance line for every settlement currency,
# which doesn't match the dashboard's USD view that finance reconciles against. The
# other accounts settle in USD only and need no filter.
module StripeBalanceSummariesReport
  # Each entry names an Antiwork Stripe account and where its restricted (reporting +
  # files read) API key lives. Gumroad reuses the platform key already configured for
  # the app; the other entities' keys are separate credentials. An entity whose key is
  # not configured is skipped and reported as such in the email rather than failing the
  # whole run.
  ENTITIES = [
    { name: "Gumroad", api_key: -> { STRIPE_SECRET }, usd_only: true },
    { name: "Flexile", api_key: -> { GlobalConfig.get("STRIPE_API_KEY_FLEXILE") }, usd_only: false },
    { name: "Helper",  api_key: -> { GlobalConfig.get("STRIPE_API_KEY_HELPER") }, usd_only: false },
    { name: "Iffy",    api_key: -> { GlobalConfig.get("STRIPE_API_KEY_IFFY") }, usd_only: false },
  ].freeze

  REPORT_TYPES = %w[balance.summary.1 balance_change_from_activity.summary.1 payouts.summary.1].freeze

  POLL_INTERVAL = 5.seconds
  # Stripe report runs usually finish in under 30 seconds but can take a few minutes
  # under load; give each one plenty of headroom before treating it as failed.
  MAX_WAIT_PER_REPORT = 10.minutes

  # Human-readable labels for the activity report's reporting_category values, matching
  # how the Stripe dashboard displays them.
  ACTIVITY_LABELS = {
    "charge" => "Charges",
    "refund" => "Refunds",
    "refund_failure" => "Refund failures",
    "dispute" => "Disputes",
    "dispute_reversal" => "Dispute reversals",
    "transfer" => "Transfers",
    "transfer_reversal" => "Transfer reversals",
    "platform_earning" => "Platform earnings",
    "platform_earning_refund" => "Platform earning refunds",
    "connect_collection_transfer" => "Connect collection transfers",
    "fee" => "Additional Stripe fees",
    "network_cost" => "Network costs",
    "payout_minimum_balance_hold" => "Payout minimum balance hold",
    "payout_minimum_balance_release" => "Payout minimum balance release",
    "revenue_share" => "Revenue share",
    "total" => "Net balance change from activity",
  }.freeze

  # Returns { csvs: { "Gumroad" => <csv string>, ... }, skipped: ["Flexile", ...] }.
  # `skipped` lists entities whose API key is not configured; a configured entity whose
  # reports fail raises instead, so Sidekiq retries (and the exhaustion alert) kick in.
  def self.generate(month, year)
    interval_start = Time.utc(year, month).to_i
    interval_end = Time.utc(year, month).next_month.to_i

    csvs = {}
    skipped = []
    ENTITIES.each do |entity|
      api_key = entity[:api_key].call
      if api_key.blank?
        skipped << entity[:name]
        next
      end

      raw_reports = REPORT_TYPES.index_with do |report_type|
        run_report(api_key:, report_type:, interval_start:, interval_end:, usd_only: entity[:usd_only])
      end
      csvs[entity[:name]] = build_combined_csv(raw_reports)
    end

    { csvs:, skipped: }
  end

  def self.run_report(api_key:, report_type:, interval_start:, interval_end:, usd_only:)
    parameters = { interval_start:, interval_end:, timezone: "Etc/UTC" }
    parameters[:currency] = "usd" if usd_only

    run = Stripe::Reporting::ReportRun.create({ report_type:, parameters: }, { api_key: })

    deadline = Time.current + MAX_WAIT_PER_REPORT
    while run.status == "pending"
      raise "Stripe report run #{run.id} (#{report_type}) timed out after #{MAX_WAIT_PER_REPORT.inspect}" if Time.current > deadline
      sleep(POLL_INTERVAL)
      run = Stripe::Reporting::ReportRun.retrieve(run.id, { api_key: })
    end
    raise "Stripe report run #{run.id} (#{report_type}) failed: #{run.error}" unless run.status == "succeeded"

    download_result(api_key, run.result.url)
  end

  # Report result files live on files.stripe.com and are fetched with the same API key
  # via basic auth. The stripe gem has no download helper for them, hence Net::HTTP.
  def self.download_result(api_key, url)
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(api_key, "")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { _1.request(request) }
    raise "Downloading Stripe report result failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  # Merges the three raw report CSVs into one CSV shaped like the Stripe dashboard's
  # Balance page: a Balance Summary section, a Balance Change from Activity section
  # (where a category with a non-zero fee shows the gross amount plus an indented fee
  # sub-line, as the dashboard does), and a Payouts section.
  def self.build_combined_csv(raw_reports)
    balance_rows = CSV.parse(raw_reports["balance.summary.1"], headers: true)
    activity_rows = CSV.parse(raw_reports["balance_change_from_activity.summary.1"], headers: true)
    payout_rows = CSV.parse(raw_reports["payouts.summary.1"], headers: true)

    CsvSafe.generate do |csv|
      csv << %w[Section Description Count Amount Currency]

      balance_rows.each do |row|
        csv << ["Balance Summary", row["description"], nil, row["net_amount"], row["currency"]]
      end

      activity_rows.each do |row|
        category = row["reporting_category"]
        label = ACTIVITY_LABELS.fetch(category) { category.to_s.tr("_", " ").capitalize }
        if category != "total" && row["fee"].to_f.nonzero?
          csv << ["Balance Change from Activity", label, row["count"], row["gross"], row["currency"]]
          csv << ["Balance Change from Activity", "  Fees (#{label})", nil, row["fee"], row["currency"]]
        else
          csv << ["Balance Change from Activity", label, row["count"], row["net"], row["currency"]]
        end
      end

      payout_rows.each do |row|
        label = row["reporting_category"] == "total" ? "Total paid out" : "Payouts"
        csv << ["Payouts", label, row["count"], row["net"], row["currency"]]
      end
    end
  end
end
