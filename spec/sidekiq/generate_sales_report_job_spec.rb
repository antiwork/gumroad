# frozen_string_literal: true

require "spec_helper"

describe GenerateSalesReportJob do
  let (:country_code) { "GB" }
  let(:start_date) { Date.new(2015, 1, 1) }
  let (:end_date) { Date.new(2015, 3, 31) }

  it "raises an argument error if the country code is not valid" do
    expect { described_class.new.perform("AUS", start_date, end_date) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/international-sales-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      travel_to(Time.zone.local(2015, 1, 1)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase2 = create(:purchase_in_progress, link: product, country: "Australia")
        @purchase3 = create(:purchase_in_progress, link: product, country: "United Kingdom")
        @purchase4 = create(:purchase_in_progress, link: product, country: "Singapore")
        @purchase5 = create(:purchase_in_progress, link: product, country: "United Kingdom")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for sales into the United Kingdom" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(country_code, start_date, end_date)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(4)
      expect(actual_payload[0]).to eq(["Sale time", "Sale ID",
                                       "Seller ID", "Seller Email",
                                       "Seller Country",
                                       "Buyer Email", "Buyer Card",
                                       "Price", "Gumroad Fee", "GST",
                                       "Shipping", "Total"])

      expect(actual_payload[1]).to eq(["2015-01-01 00:00:00 UTC", @purchase1.external_id,
                                       @purchase1.seller.external_id, @purchase1.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                       nil,
                                       @purchase1.email&.gsub(/.{0,4}@/, '####@'), "**** **** **** 4242",
                                       "10000", "1370", "0",
                                       "0", "10000"])

      expect(actual_payload[2]).to eq(["2015-01-01 00:00:00 UTC", @purchase3.external_id,
                                       @purchase3.seller.external_id, @purchase3.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                       nil,
                                       @purchase3.email&.gsub(/.{0,4}@/, '####@'), "**** **** **** 4242",
                                       "10000", "1370", "0",
                                       "0", "10000"])

      expect(actual_payload[3]).to eq(["2015-01-01 00:00:00 UTC", @purchase5.external_id,
                                       @purchase5.seller.external_id, @purchase5.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                       nil,
                                       @purchase5.email&.gsub(/.{0,4}@/, '####@'), "**** **** **** 4242",
                                       "10000", "1370", "0",
                                       "0", "10000"])
    end

    it "creates a CSV file for sales into Australia" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform("AU", start_date, end_date)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(2)
      expect(actual_payload[0]).to eq(["Sale time", "Sale ID",
                                       "Seller ID", "Seller Email",
                                       "Seller Country",
                                       "Buyer Email", "Buyer Card",
                                       "Price", "Gumroad Fee", "GST",
                                       "Shipping", "Total",
                                       "Direct-To-Customer / Buy-Sell", "Zip Tax Rate ID", "Customer ABN Number"])

      expect(actual_payload[1]).to eq(["2015-01-01 00:00:00 UTC", @purchase2.external_id,
                                       @purchase2.seller.external_id, @purchase2.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                       nil,
                                       @purchase2.email&.gsub(/.{0,4}@/, '####@'), "**** **** **** 4242",
                                       "10000", "1370", "0",
                                       "0", "10000",
                                       "BS", nil, nil])
    end

    it "creates a CSV file for sales into Singapore" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform("SG", start_date, end_date)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "GST Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(2)
      expect(actual_payload[0]).to eq(["Sale time", "Sale ID",
                                       "Seller ID", "Seller Email",
                                       "Seller Country",
                                       "Buyer Email", "Buyer Card",
                                       "Price", "Gumroad Fee", "GST",
                                       "Shipping", "Total",
                                       "Direct-To-Customer / Buy-Sell", "Zip Tax Rate ID", "Customer GST Number"])

      expect(actual_payload[1]).to eq(["2015-01-01 00:00:00 UTC", @purchase4.external_id,
                                       @purchase4.seller.external_id, @purchase4.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                       nil,
                                       @purchase4.email&.gsub(/.{0,4}@/, '####@'), "**** **** **** 4242",
                                       "10000", "1370", "0",
                                       "0", "10000",
                                       "BS", nil, nil])
    end

    it "creates a CSV file for sales into the United Kingdom and does not send slack notification when send_notification is false",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(country_code, start_date, end_date, false)

      expect(SlackMessageWorker.jobs.size).to eq(0)
    end

    it "creates a CSV file for sales into the United Kingdom and sends slack notification when send_notification is true",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(country_code, start_date, end_date, true)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end

    it "creates a CSV file for sales into the United Kingdom and sends slack notification when send_notification is not provided (default behavior)",
       vcr: { cassette_name: "GenerateSalesReportJob/happy_case/creates_a_CSV_file_for_sales_into_the_United_Kingdom" } do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(country_code, start_date, end_date)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")
    end
  end

  describe "s3_prefix functionality", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/international-sales-reporting-spec-#{SecureRandom.hex(18)}.zip")
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
      expect(s3_bucket_double).to receive(:object) do |key|
        expect(key).to start_with("#{custom_prefix}/sales-tax/gb-sales-quarterly/")
        expect(key).to include("united-kingdom-sales-report-2015-01-01-to-2015-03-31")
        @s3_object
      end

      described_class.new.perform(country_code, start_date, end_date, true, custom_prefix)
    end

    it "handles s3_prefix with trailing slash" do
      custom_prefix = "custom/reports/"
      expect(s3_bucket_double).to receive(:object) do |key|
        expect(key).to start_with("custom/reports/sales-tax/gb-sales-quarterly/")
        expect(key).not_to include("//")
        expect(key).to include("united-kingdom-sales-report-2015-01-01-to-2015-03-31")
        @s3_object
      end

      described_class.new.perform(country_code, start_date, end_date, true, custom_prefix)
    end

    it "uses default path when s3_prefix is nil" do
      expect(s3_bucket_double).to receive(:object) do |key|
        expect(key).to start_with("sales-tax/gb-sales-quarterly/")
        expect(key).to include("united-kingdom-sales-report-2015-01-01-to-2015-03-31")
        @s3_object
      end

      described_class.new.perform(country_code, start_date, end_date, true, nil)
    end

    it "uses default path when s3_prefix is empty string" do
      expect(s3_bucket_double).to receive(:object) do |key|
        expect(key).to start_with("sales-tax/gb-sales-quarterly/")
        expect(key).to include("united-kingdom-sales-report-2015-01-01-to-2015-03-31")
        @s3_object
      end

      described_class.new.perform(country_code, start_date, end_date, true, "")
    end
  end
end
