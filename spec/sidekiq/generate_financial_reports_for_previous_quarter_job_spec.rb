# frozen_string_literal: true

describe GenerateFinancialReportsForPreviousQuarterJob do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "fans out the quarterly report jobs for the previous quarter by default" do
    travel_to(Time.utc(2026, 7, 5, 11)) do
      described_class.new.perform

      expect(CreateVatReportJob).to have_enqueued_sidekiq_job(2, 2026)
      %w[GB AU SG NO].each do |alpha2|
        expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(alpha2, "2026-04-01", "2026-06-30", GenerateSalesReportJob::ALL_SALES)
      end
    end
  end

  it "fans out for the given quarter when quarter and year are passed explicitly" do
    described_class.new.perform(1, 2026)

    expect(CreateVatReportJob).to have_enqueued_sidekiq_job(1, 2026)
    %w[GB AU SG NO].each do |alpha2|
      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(alpha2, "2026-01-01", "2026-03-31", GenerateSalesReportJob::ALL_SALES)
    end
  end

  it "raises on an invalid quarter" do
    expect { described_class.new.perform(5, 2026) }.to raise_error(ArgumentError, "Invalid quarter")
  end

  describe ".default_alert_args" do
    it "resolves to the previous quarter" do
      travel_to(Time.utc(2026, 7, 5, 11)) do
        expect(described_class.default_alert_args).to eq([2, 2026])
      end
    end
  end
end
