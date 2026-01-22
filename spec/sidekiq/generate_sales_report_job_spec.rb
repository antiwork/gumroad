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

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
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

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")
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

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")
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

    it "creates a CSV file for sales into the United Kingdom and does not send slack notification when send_notification is false",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, false)

      expect(SlackMessageWorker.jobs.size).to eq(0)
    end

    it "creates a CSV file for sales into the United Kingdom and sends slack notification when send_notification is true",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES, true)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end

    it "creates a CSV file for sales into the United Kingdom and sends slack notification when send_slack_notification is not provided (default behavior)",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(ExpiringS3FileService).to receive(:new).and_return(@mock_service)

      described_class.new.perform(country_code, start_date, end_date, GenerateSalesReportJob::ALL_SALES)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
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

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
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
end
