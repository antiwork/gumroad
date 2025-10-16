# frozen_string_literal: true

require "spec_helper"

describe Admin::SalesReport do
  let(:valid_attributes) do
    {
      country_code: "US",
      start_date: "2023-01-01",
      end_date: "2023-12-31"
    }
  end

  describe "validations" do
    context "country_code" do
      it "is invalid when country_code is blank" do
        sales_report = described_class.new(valid_attributes.merge(country_code: ""))

        expect(sales_report).not_to be_valid
        expect(sales_report.errors[:country_code]).to include("Please select a country")
      end

      it "is valid when country_code is present" do
        sales_report = described_class.new(valid_attributes)

        expect(sales_report).to be_valid
      end
    end

    context "start_date" do
      it "is invalid when start_date is blank" do
        sales_report = described_class.new(valid_attributes.merge(start_date: ""))

        expect(sales_report).not_to be_valid
        expect(sales_report.errors[:start_date]).to include("Invalid date format. Please use YYYY-MM-DD format")
      end

      it "is invalid when start_date is in the future" do
        sales_report = described_class.new(valid_attributes.merge(start_date: 1.day.from_now.to_date))

        expect(sales_report).not_to be_valid
        expect(sales_report.errors[:start_date]).to include("cannot be in the future")
      end

      it "is invalid when start_date is greater than or equal to end_date" do
        sales_report = described_class.new(valid_attributes.merge(start_date: "2023-12-31", end_date: "2023-01-01"))

        expect(sales_report).not_to be_valid
        expect(sales_report.errors[:start_date]).to include("must be before end date")
      end

      it "is valid when start_date is less than end_date" do
        sales_report = described_class.new(valid_attributes)

        expect(sales_report).to be_valid
      end

      it "is valid when start_date is today and end_date is in the future" do
        sales_report = described_class.new(valid_attributes.merge(start_date: Date.current, end_date: Date.current + 1.day))

        expect(sales_report).to be_valid
      end
    end

    context "end_date" do
      it "is invalid when end_date is blank" do
        sales_report = described_class.new(valid_attributes.merge(end_date: ""))

        expect(sales_report).not_to be_valid
        expect(sales_report.errors[:end_date]).to include("Invalid date format. Please use YYYY-MM-DD format")
      end

      it "is valid when end_date is present" do
        sales_report = described_class.new(valid_attributes)

        expect(sales_report).to be_valid
      end
    end
  end

  describe "date parsing" do
    context "start_date=" do
      it "parses a valid date string in YYYY-MM-DD format" do
        sales_report = described_class.new(start_date: "2023-01-15")

        expect(sales_report.start_date).to eq(Date.new(2023, 1, 15))
      end

      it "accepts a Date object" do
        date = Date.new(2023, 1, 15)
        sales_report = described_class.new(start_date: date)

        expect(sales_report.start_date).to eq(date)
      end

      it "returns nil for invalid date string format" do
        sales_report = described_class.new(start_date: "01/15/2023")

        expect(sales_report.start_date).to be_nil
      end

      it "returns nil for unparseable date string" do
        sales_report = described_class.new(start_date: "2023-13-45")

        expect(sales_report.start_date).to be_nil
      end

      it "returns nil for blank value" do
        sales_report = described_class.new(start_date: "")

        expect(sales_report.start_date).to be_nil
      end
    end

    context "end_date=" do
      it "parses a valid date string in YYYY-MM-DD format" do
        sales_report = described_class.new(end_date: "2023-12-31")

        expect(sales_report.end_date).to eq(Date.new(2023, 12, 31))
      end

      it "accepts a Date object" do
        date = Date.new(2023, 12, 31)
        sales_report = described_class.new(end_date: date)

        expect(sales_report.end_date).to eq(date)
      end

      it "returns nil for invalid date string format" do
        sales_report = described_class.new(end_date: "12/31/2023")

        expect(sales_report.end_date).to be_nil
      end

      it "returns nil for unparseable date string" do
        sales_report = described_class.new(end_date: "2023-13-45")

        expect(sales_report.end_date).to be_nil
      end

      it "returns nil for blank value" do
        sales_report = described_class.new(end_date: "")

        expect(sales_report.end_date).to be_nil
      end
    end
  end

  describe "accessor predicate methods" do
    it "returns true when country_code is present" do
      sales_report = described_class.new(country_code: "US")

      expect(sales_report.country_code?).to be true
    end

    it "returns false when country_code is blank" do
      sales_report = described_class.new(country_code: "")

      expect(sales_report.country_code?).to be false
    end

    it "returns true when start_date is present" do
      sales_report = described_class.new(start_date: "2023-01-01")

      expect(sales_report.start_date?).to be true
    end

    it "returns false when start_date is blank" do
      sales_report = described_class.new(start_date: "")

      expect(sales_report.start_date?).to be false
    end

    it "returns true when end_date is present" do
      sales_report = described_class.new(end_date: "2023-12-31")

      expect(sales_report.end_date?).to be true
    end

    it "returns false when end_date is blank" do
      sales_report = described_class.new(end_date: "")

      expect(sales_report.end_date?).to be false
    end
  end

  describe "#generate_later" do
    let(:sales_report) { described_class.new(valid_attributes) }

    before do
      allow($redis).to receive(:lpush)
      allow($redis).to receive(:ltrim)
    end

    it "enqueues a GenerateSalesReportJob" do
      sales_report.generate_later

      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(
        "US",
        "2023-01-01",
        "2023-12-31",
        true,
        nil
      )
    end

    it "stores job details in Redis with the correct key" do
      allow(GenerateSalesReportJob).to receive(:perform_async).and_return("job_123")

      expect($redis).to receive(:lpush).with(RedisKey.sales_report_jobs, anything)
      expect($redis).to receive(:ltrim).with(RedisKey.sales_report_jobs, 0, 19)

      sales_report.generate_later
    end

    it "stores job details with correct attributes" do
      allow(GenerateSalesReportJob).to receive(:perform_async).and_return("job_123")
      allow(Time).to receive(:current).and_return(Time.new(2023, 1, 1, 12, 0, 0))

      expect($redis).to receive(:lpush) do |key, json_data|
        data = JSON.parse(json_data)
        expect(data["job_id"]).to eq("job_123")
        expect(data["country_code"]).to eq("US")
        expect(data["start_date"]).to eq("2023-01-01")
        expect(data["end_date"]).to eq("2023-12-31")
        expect(data["enqueued_at"]).to be_present
        expect(data["status"]).to eq("processing")
      end

      sales_report.generate_later
    end

    it "limits the job history to 20 items" do
      allow(GenerateSalesReportJob).to receive(:perform_async).and_return("job_123")

      expect($redis).to receive(:ltrim).with(RedisKey.sales_report_jobs, 0, 19)

      sales_report.generate_later
    end
  end

  describe ".fetch_job_history" do
    context "when job data exists" do
      let(:job_data) do
        [
          {
            job_id: "job_1",
            country_code: "US",
            start_date: "2023-01-01",
            end_date: "2023-03-31",
            enqueued_at: "2023-01-01T00:00:00Z",
            status: "processing"
          }.to_json,
          {
            job_id: "job_2",
            country_code: "GB",
            start_date: "2023-04-01",
            end_date: "2023-06-30",
            enqueued_at: "2023-04-01T00:00:00Z",
            status: "completed"
          }.to_json
        ]
      end

      before do
        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return(job_data)
      end

      it "fetches and parses job history from Redis" do
        result = described_class.fetch_job_history

        expect(result).to be_an(Array)
        expect(result.size).to eq(2)
        expect(result[0]["job_id"]).to eq("job_1")
        expect(result[1]["job_id"]).to eq("job_2")
      end

      it "returns the last 20 jobs" do
        described_class.fetch_job_history

        expect($redis).to have_received(:lrange).with(RedisKey.sales_report_jobs, 0, 19)
      end
    end

    context "when Redis returns empty array" do
      before do
        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return([])
      end

      it "returns an empty array" do
        result = described_class.fetch_job_history

        expect(result).to eq([])
      end
    end

    context "when JSON parsing fails" do
      before do
        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return(["invalid json"])
      end

      it "returns an empty array" do
        result = described_class.fetch_job_history

        expect(result).to eq([])
      end
    end
  end

  describe "#errors_hash" do
    it "returns errors in the expected format" do
      sales_report = described_class.new(country_code: "", start_date: "", end_date: "")
      sales_report.valid?

      errors = sales_report.errors_hash

      expect(errors).to have_key(:sales_report)
      expect(errors[:sales_report]).to be_a(Hash)
      expect(errors[:sales_report][:country_code]).to include("Please select a country")
      expect(errors[:sales_report][:start_date]).to include("Invalid date format. Please use YYYY-MM-DD format")
      expect(errors[:sales_report][:end_date]).to include("Invalid date format. Please use YYYY-MM-DD format")
    end

    it "returns empty hash when there are no errors" do
      sales_report = described_class.new(valid_attributes)
      sales_report.valid?

      errors = sales_report.errors_hash

      expect(errors).to eq({ sales_report: {} })
    end
  end
end
