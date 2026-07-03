# frozen_string_literal: true

describe GenerateFinancialReportsForPreviousMonthJob do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "fans out the monthly report jobs for the previous month by default" do
    travel_to(Time.utc(2026, 7, 1, 11)) do
      described_class.new.perform

      expect(CreateCanadaMonthlySalesReportJob).to have_enqueued_sidekiq_job(6, 2026)
      expect(GenerateFeesByCreatorLocationReportJob).to have_enqueued_sidekiq_job(6, 2026)
      expect(CreateUsStatesSalesSummaryReportJob).to have_enqueued_sidekiq_job(Compliance::Countries::TAXABLE_US_STATE_CODES, 6, 2026)
      expect(GenerateCanadaSalesReportJob).to have_enqueued_sidekiq_job(6, 2026)
      expect(CreateGlobalSalesTaxSummaryReportJob).to have_enqueued_sidekiq_job(6, 2026)
    end
  end

  it "fans out for the given month when month and year are passed explicitly" do
    described_class.new.perform(3, 2026)

    expect(CreateCanadaMonthlySalesReportJob).to have_enqueued_sidekiq_job(3, 2026)
    expect(GenerateFeesByCreatorLocationReportJob).to have_enqueued_sidekiq_job(3, 2026)
    expect(CreateUsStatesSalesSummaryReportJob).to have_enqueued_sidekiq_job(Compliance::Countries::TAXABLE_US_STATE_CODES, 3, 2026)
    expect(GenerateCanadaSalesReportJob).to have_enqueued_sidekiq_job(3, 2026)
    expect(CreateGlobalSalesTaxSummaryReportJob).to have_enqueued_sidekiq_job(3, 2026)
  end

  it "raises on an invalid month" do
    expect { described_class.new.perform(13, 2026) }.to raise_error(ArgumentError, "Invalid month")
  end

  describe ".default_alert_args" do
    it "resolves to the previous month" do
      travel_to(Time.utc(2026, 7, 1, 11)) do
        expect(described_class.default_alert_args).to eq([6, 2026])
      end
    end
  end
end
