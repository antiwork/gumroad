# frozen_string_literal: true

# THROWAWAY profiling harness for antiwork/gumroad-private#2625. Not part of the shipped
# change: it seeds a fixture month, then measures (a) the per-row query cost of each leg's row
# builders with and without the associations the job now preloads, and (b) the whole job
# end-to-end, capturing the CSV it uploads so two revisions can be compared byte for byte.
require "spec_helper"
require "json"
require "fileutils"

describe CreateIndiaSalesReportJob, "gp2625 profile", type: :model do
  self.use_transactional_tests = false

  N = Integer(ENV.fetch("GP2625_N", "60"))
  LABEL = ENV.fetch("GP2625_LABEL", "run")
  DO_SEED = ENV["GP2625_SEED"] == "1"
  OUT = ENV.fetch("GP2625_OUT", "/tmp/gp2625")

  MONTH = Time.zone.local(2026, 8, 1)
  START_DATE = MONTH.beginning_of_month.beginning_of_day
  END_DATE = MONTH.end_of_month.end_of_day
  CUTOVER = Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day
  PRELOADS = [:disputes, :refunds, { charge: :dispute }].freeze

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_queries
    queries = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      queries << payload[:sql].to_s.squish
    end
    started = clock
    yield
    elapsed = clock - started
    ActiveSupport::Notifications.unsubscribe(sub)
    [elapsed, queries]
  end

  def make_purchase(key, created_at:, price_cents: 1000, tax_cents: 180, country: "India", ip_country: "India", ip_state: "MH", **attrs)
    existing = Purchase.find_by(stripe_transaction_id: key)
    return existing if existing

    create(:purchase,
           link: @product,
           purchaser: @product.user,
           purchase_state: "successful",
           succeeded_at: created_at,
           quantity: 1,
           price_cents:,
           perceived_price_cents: price_cents,
           total_transaction_cents: price_cents + tax_cents,
           gumroad_tax_cents: tax_cents,
           country:,
           ip_country:,
           ip_state:,
           created_at:,
           stripe_transaction_id: key,
           **attrs)
  end

  def seed_dataset!
    @product ||= Link.first || create(:product, price_cents: 1000)

    create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false) unless ZipTaxRate.where(country: "IN", state: nil).exists?

    states = ["MH", "KA", "ZZ", "123", ""]

    # Sale leg: N Indian sales spread across the month. Index 0 is a non-India purchase
    # (must be excluded by every leg's filters).
    N.times do |i|
      created_at = START_DATE + (i % 28).days + (9 + (i % 8)).hours
      if i.zero?
        make_purchase("gp2625-nonindia-#{i}", created_at:, country: "US", ip_country: "US", ip_state: "CA")
      else
        make_purchase("gp2625-sale-#{i}", created_at:, ip_state: states[i % states.length])
      end
    end

    # A VAT-registered Indian purchase: excluded by the sales leg's sales-tax-info filter.
    vat = make_purchase("gp2625-vat", created_at: START_DATE + 3.days)
    vat.create_purchase_sales_tax_info!(business_vat_id: "GST9999") unless vat.purchase_sales_tax_info

    # Legacy (pre-cutover) chargeback with its sale inside the report month: the `next if` in
    # the sales leg must still drop it.
    legacy = make_purchase("gp2625-legacy-cb", created_at: START_DATE + 5.days)
    legacy.update!(chargeback_date: CUTOVER - 14.days) if legacy.chargeback_date.nil?

    # Refund leg: sales refunded inside the month, plus two terminally-failed variants
    # (still-debited keeps its refund row; balance-reversed is dropped by Refund.effective).
    5.times do |i|
      purchase = make_purchase("gp2625-refund-#{i}", created_at: START_DATE + (2 + i).days)
      next if purchase.refunds.exists?

      create(:refund, purchase:, amount_cents: 1000, gumroad_tax_cents: 180, created_at: START_DATE + (10 + i).days)
    end

    2.times do |i|
      purchase = make_purchase("gp2625-failed-refund-#{i}", created_at: START_DATE + (2 + i).days)
      next if purchase.refunds.exists?

      refund = create(:refund, purchase:, amount_cents: 1000, gumroad_tax_cents: 180,
                               created_at: START_DATE + (12 + i).days, status: "failed")
      if i == 1
        refund.balance_reversed_on_failure = true
        refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
        refund.save!
      end
    end

    # Chargeback debit leg: dispute formalized inside the month, bought in the previous month.
    lost = make_purchase("gp2625-cb-lost", created_at: START_DATE - 20.days, tax_cents: 540, price_cents: 3000)
    unless lost.disputes.exists?
      create(:refund, purchase: lost, amount_cents: 300, gumroad_tax_cents: 54, created_at: START_DATE - 19.days)
      lost.update!(chargeback_date: START_DATE + 6.days)
      create(:dispute, purchase: lost, state: "lost", event_created_at: START_DATE + 6.days, won_at: nil)
    end

    # Chargeback-reversal leg: same shape, but the dispute was won inside the month.
    won = make_purchase("gp2625-cb-won", created_at: START_DATE - 18.days, tax_cents: 540, price_cents: 3000)
    return if won.disputes.exists?

    won.update!(chargeback_date: START_DATE + 7.days)
    create(:dispute, purchase: won, state: "won", event_created_at: START_DATE + 7.days, won_at: START_DATE + 9.days)
    won.update!(chargeback_reversed: true)
  end

  it "profiles the legs and the end-to-end job" do
    FileUtils.mkdir_p(OUT)
    seed_dataset! if DO_SEED

    job = described_class.new
    rate = job.send(:india_gst_combined_rate)
    pct = (rate * 100).to_i

    scopes = {
      "sales" => ->(ids) { job.send(:india_purchases, START_DATE, END_DATE).where(id: ids) },
      "refunds" => ->(ids) { job.send(:india_refunds, START_DATE, END_DATE).where(id: ids) },
      "chargebacks" => ->(ids) { job.send(:india_chargebacks, START_DATE, END_DATE).where(id: ids) },
      "reversals" => ->(ids) { job.send(:india_chargeback_reversals, START_DATE, END_DATE).where(id: ids) },
    }

    leg_ids = {
      "sales" => job.send(:india_purchases, START_DATE, END_DATE).pluck(:id),
      "refunds" => job.send(:india_refunds, START_DATE, END_DATE).pluck(:id),
      "chargebacks" => job.send(:india_chargebacks, START_DATE, END_DATE).pluck(:id),
      "reversals" => job.send(:india_chargeback_reversals, START_DATE, END_DATE).pluck(:id),
    }

    legs = {}
    leg_ids.each do |name, ids|
      if ids.empty?
        legs[name] = { "rows" => 0, "without_preload" => nil, "with_preload" => nil }
        next
      end

      unloaded_ms, unloaded_queries = with_queries { scopes[name].call(ids).each { |row| send_leg(name, job, row, rate, pct) } }
      preloaded_ms, preloaded_queries = with_queries do
        relation = name == "refunds" ? scopes[name].call(ids).preload(purchase: PRELOADS) : scopes[name].call(ids).preload(*PRELOADS)
        relation.each { |row| send_leg(name, job, row, rate, pct) }
      end

      legs[name] = {
        "rows" => ids.length,
        "without_preload" => { "ms" => (unloaded_ms * 1000).round(1), "queries" => unloaded_queries.length },
        "with_preload" => { "ms" => (preloaded_ms * 1000).round(1), "queries" => preloaded_queries.length },
      }
    end

    # End-to-end job on the same rows: captures the uploaded CSV and the wall time.
    uploaded = nil
    s3_object = double
    allow(s3_object).to receive(:upload_file) { |file| uploaded = File.join(OUT, "#{LABEL}-job.csv"); FileUtils.cp(file.path, uploaded) }
    allow(s3_object).to receive(:presigned_url).and_return("https://example.com/x")
    bucket = double
    allow(bucket).to receive(:object).and_return(s3_object)
    allow(Aws::S3::Resource).to receive(:new).and_return(double(bucket:))
    allow(InternalNotificationWorker).to receive(:perform_async)

    job_seconds, job_queries = with_queries { described_class.new.perform(8, 2026) }

    summary = {
      "label" => LABEL,
      "seeded" => DO_SEED,
      "n" => N,
      "fixture_rows" => leg_ids.transform_values(&:length),
      "legs" => legs,
      "job" => {
        "seconds" => job_seconds.round(3),
        "queries" => job_queries.length,
        "query_shapes" => job_queries.map { |sql| sql[0, 60] }.tally.sort_by { |_k, v| -v }.first(8).to_h,
        "uploaded_bytes" => uploaded && File.size(uploaded),
        "sha256" => uploaded && Digest::SHA256.hexdigest(File.read(uploaded, mode: "rb")),
        "csv_lines" => uploaded && File.read(uploaded).lines.length,
      },
      "ruby" => RUBY_VERSION,
    }
    File.write(File.join(OUT, "#{LABEL}.json"), JSON.pretty_generate(summary))
    puts summary.to_json
  end

  # Mirrors the job's per-row branch: the chargeback predicates plus the row builder.
  def send_leg(name, job, row, rate, pct)
    case name
    when "sales"
      return if row.chargedback_not_reversed? && !row.chargeback_event_dated_for_tax_reporting?

      job.send(:sale_row, row, rate, pct)
    when "refunds"
      purchase = row.purchase
      return if purchase.chargedback_not_reversed? && !purchase.chargeback_event_dated_for_tax_reporting?

      job.send(:refund_row, row, purchase, rate, pct)
    when "chargebacks"
      job.send(:chargeback_row, row, rate, pct)
    when "reversals"
      won_at = row.chargeback_reversal_reporting_date
      return unless won_at&.between?(START_DATE, END_DATE)

      job.send(:chargeback_reversal_row, row, won_at, rate, pct)
    end
  end
end