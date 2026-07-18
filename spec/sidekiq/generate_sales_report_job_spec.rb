# frozen_string_literal: true

require "spec_helper"

describe GenerateSalesReportJob do
  let (:country_code) { "GB" }
  let(:start_date) { Date.new(2015, 1, 1) }
  let (:end_date) { Date.new(2015, 3, 31) }

  it "raises an argument error if the country code is not valid" do
    expect { described_class.new.perform("AUS", start_date, end_date, GenerateSalesReportJob::ALL_SALES) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the sales_type is neither all_sales nor discover_sales" do
    expect { described_class.new.perform("AU", start_date, end_date, nil) }.to raise_error(ArgumentError)
    expect { described_class.new.perform("AU", start_date, end_date, "abc") }.to raise_error(ArgumentError)
    expect { described_class.new.perform("AU", start_date, end_date, "all") }.to raise_error(ArgumentError)
    expect { described_class.new.perform("AU", start_date, end_date, "discover") }.to raise_error(ArgumentError)
    expect { described_class.new.perform("AU", start_date, end_date, GenerateSalesReportJob::ALL_SALES) }.not_to raise_error(ArgumentError)
    expect { described_class.new.perform("AU", start_date, end_date, GenerateSalesReportJob::DISCOVER_SALES) }.not_to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    before do
      @mock_service = double("ExpiringS3FileService")
      allow(ExpiringS3FileService).to receive(:new).and_return(@mock_service)
      allow(@mock_service).to receive(:perform).and_return("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/test-url")
    end

    before do
      travel_to(Time.zone.local(2015, 1, 1)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase2 = create(:purchase_in_progress, link: product, country: "Australia")
        @purchase3 = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase4 = create(:purchase_in_progress, link: product, country: "Singapore")
        @purchase5 = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase6 = create(:purchase_in_progress, link: product, recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION, country: "United Kingdom")
        @purchase7 = create(:purchase_in_progress, link: product, recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION, country: "United Kingdom")
        @purchase8 = create(:purchase_in_progress, link: product, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, country: "United Kingdom")
        @purchase9 = create(:purchase_in_progress, link: product, recommended_by: RecommendationType::GUMROAD_STAFF_PICKS_RECOMMENDATION, country: "United Kingdom")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for sales into the United Kingdom" do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        expect(args[:expiry]).to eq(1.week)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end

    it "creates a CSV file for sales into Australia" do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/au-sales-quarterly")
        expect(args[:filename]).to include("australia-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        expect(args[:expiry]).to eq(1.week)
        @mock_service
      end

      described_class.new.perform("AU", start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")
    end

    it "creates a CSV file for sales into Singapore" do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/sg-sales-quarterly")
        expect(args[:filename]).to include("singapore-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        expect(args[:expiry]).to eq(1.week)
        @mock_service
      end

      described_class.new.perform("SG", start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")
    end

    it "includes Customer Tax ID column in CSV", vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      @purchase1.create_purchase_sales_tax_info!(business_vat_id: "GB123456789")

      csv_content = nil
      expect(ExpiringS3FileService).to receive(:new) do |args|
        csv_content = args[:file].read
        args[:file].rewind
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      csv = CSV.parse(csv_content, headers: true)
      expect(csv.headers).to include("Customer Tax ID")
      expect(csv.map { |row| row["Customer Tax ID"] }).to include("GB123456789")
    end

    it "creates a CSV file for sales into the United Kingdom and does not send notification when send_notification is false",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, false)

      expect(InternalNotificationWorker.jobs.size).to eq(0)
    end

    it "creates a CSV file for sales into the United Kingdom and sends notification when send_notification is true",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end

    it "creates a CSV file for sales into the United Kingdom and sends notification when send_notification is not provided (default behavior)",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end

    it "creates a CSV file for discover sales into the United Kingdom sales_type is set as discover_sales",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_discover_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-discover-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        expect(args[:expiry]).to eq(1.week)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::DISCOVER_SALES)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end
  end

  describe "s3_prefix functionality", :vcr do
    before do
      @mock_service = double("ExpiringS3FileService")
      allow(ExpiringS3FileService).to receive(:new).and_return(@mock_service)
      allow(@mock_service).to receive(:perform).and_return("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/test-url")
    end

    before do
      travel_to(Time.zone.local(2015, 1, 1)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        @purchase = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase.chargeable = create(:chargeable)
        @purchase.process!
        @purchase.update_balance_and_mark_successful!
      end
    end

    it "uses custom s3_prefix when provided" do
      custom_prefix = "custom/reports"
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("#{custom_prefix}/sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true, custom_prefix)
    end

    it "handles s3_prefix with trailing slash" do
      custom_prefix = "custom/reports/"
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("custom/reports/sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true, custom_prefix)
    end

    it "uses default path when s3_prefix is nil" do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true, nil)
    end

    it "uses default path when s3_prefix is empty string" do
      expect(ExpiringS3FileService).to receive(:new) do |args|
        expect(args[:path]).to eq("sales-tax/gb-sales-quarterly")
        expect(args[:filename]).to include("united-kingdom-all-sales-report-2015-01-01-to-2015-03-31")
        expect(args[:bucket]).to eq(REPORTING_S3_BUCKET)
        @mock_service
      end

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true, "")
    end
  end

  describe "refund period attribution" do
    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
    let(:report_quarter_start) { (cutover + 3.months).beginning_of_quarter }
    let(:report_quarter_end) { report_quarter_start.end_of_quarter }

    before do
      @mock_service = double("ExpiringS3FileService")
      allow(@mock_service).to receive(:perform).and_return("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/test-url")

      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold (post-cutover) in the quarter before the reported one, refunded during the
      # reported quarter: the refund must appear in the reported quarter as a negative row.
      travel_to(report_quarter_start - 10.days) do
        @cross_quarter_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                    gumroad_tax_cents: 20_00, total_transaction_cents: 120_00,
                                                    country: "United Kingdom")
      end

      travel_to(report_quarter_start + 10.days) do
        @refund = create(:refund, purchase: @cross_quarter_purchase, amount_cents: 50_00, fee_cents: 15_00,
                                  gumroad_tax_cents: 10_00, total_transaction_cents: 60_00)
        @cross_quarter_purchase.update!(stripe_partially_refunded: true)
      end
    end

    it "reports the refund as a negative row dated by the refund's date" do
      csv_content = nil
      expect(ExpiringS3FileService).to receive(:new) do |args|
        csv_content = args[:file].read
        args[:file].rewind
        @mock_service
      end

      described_class.new.perform("GB", report_quarter_start.to_date, report_quarter_end.to_date, GenerateSalesReportJob::ALL_SALES)

      csv = CSV.parse(csv_content, headers: true)
      # The purchase's sale row belongs to the previous quarter, so this quarter contains
      # only the refund row.
      expect(csv.length).to eq(1)
      refund_row = csv[0]
      expect(refund_row["Sale ID"]).to eq(@cross_quarter_purchase.external_id)
      expect(refund_row["Sale time"]).to eq(@refund.created_at.to_s)
      expect(refund_row["Price"]).to eq("-5000")
      expect(refund_row["Gumroad Fee"]).to eq("-1500")
      expect(refund_row["GST"]).to eq("-1000")
      expect(refund_row["Total"]).to eq("-6000")
    end

    it "does not restate the purchase's own quarter when re-generated after the refund" do
      csv_content = nil
      expect(ExpiringS3FileService).to receive(:new) do |args|
        csv_content = args[:file].read
        args[:file].rewind
        @mock_service
      end

      purchase_quarter_start = (report_quarter_start - 3.months).beginning_of_quarter
      described_class.new.perform("GB", purchase_quarter_start.to_date, purchase_quarter_start.end_of_quarter.to_date, GenerateSalesReportJob::ALL_SALES)

      csv = CSV.parse(csv_content, headers: true)
      # The sale quarter regenerates with the purchase at its gross amounts — the later refund
      # belongs to the following quarter and must not leak backwards.
      expect(csv.length).to eq(1)
      sale_row = csv[0]
      expect(sale_row["Sale ID"]).to eq(@cross_quarter_purchase.external_id)
      expect(sale_row["Price"]).to eq("10000")
    end
  end

  describe "#update_job_status_to_completed" do
    let(:job_attributes) do
      {
        job_id: "some_jid",
        country_code: "GB",
        start_date: "2015-01-01",
        end_date: "2015-03-31",
        sales_type: GenerateSalesReportJob::ALL_SALES,
        enqueued_at: "2015-01-01T00:00:00Z",
      }
    end

    def stub_history_with(status:)
      entry = job_attributes.merge(status:).to_json
      allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return([entry])
      allow($redis).to receive(:lset)
    end

    def run_update
      described_class.new.send(
        :update_job_status_to_completed,
        "GB",
        Date.parse("2015-01-01").beginning_of_day,
        Date.parse("2015-03-31").end_of_day,
        GenerateSalesReportJob::ALL_SALES,
        "https://example.com/report.csv"
      )
    end

    it "flips a processing entry to completed" do
      stub_history_with(status: "processing")

      run_update

      expect($redis).to have_received(:lset).with(RedisKey.sales_report_jobs, 0, a_string_including("\"completed\""))
    end

    it "flips a failed entry to completed when the job was retried from the Dead set and succeeded" do
      # The admin page marks an entry "failed" when its job lands in the Dead
      # set. Retrying that job from the Sidekiq UI re-runs this same code, so
      # a successful retry must be able to overwrite the "failed" status —
      # otherwise the report shows as failed forever despite the file existing.
      stub_history_with(status: "failed")

      run_update

      expect($redis).to have_received(:lset).with(RedisKey.sales_report_jobs, 0, a_string_including("\"completed\""))
    end

    it "does not touch entries that are already completed" do
      stub_history_with(status: "completed")

      run_update

      expect($redis).not_to have_received(:lset)
    end
  end
end
