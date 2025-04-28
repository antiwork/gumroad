# frozen_string_literal: true

require "spec_helper"

describe GenerateFinancialReportsForPreviousMonthJob do
  describe ".perform" do
    it "does not generate any reports when the Rails environment is not production" do
      described_class.new.perform

      expect(CreateCanadaMonthlySalesReportJob.jobs.size).to eq(0)
      expect(GenerateFeesByCreatorLocationReportJob.jobs.size).to eq(0)
      expect(CreateUsStatesSalesSummaryReportJob.jobs.size).to eq(0)
      expect(GenerateCanadaSalesReportJob.jobs.size).to eq(0)
    end

    it "generates reports when the Rails environment is production" do
      allow(Rails.env).to receive(:production?).and_return(true)

      described_class.new.perform

      expect(CreateCanadaMonthlySalesReportJob).to have_enqueued_sidekiq_job(an_instance_of(Integer), an_instance_of(Integer))
      expect(GenerateFeesByCreatorLocationReportJob).to have_enqueued_sidekiq_job(an_instance_of(Integer), an_instance_of(Integer))
      expect(CreateUsStatesSalesSummaryReportJob).to have_enqueued_sidekiq_job(Compliance::Countries::TAXABLE_US_STATE_CODES, an_instance_of(Integer), an_instance_of(Integer))
      expect(GenerateCanadaSalesReportJob).to have_enqueued_sidekiq_job(an_instance_of(Integer), an_instance_of(Integer))
    end
  end
end
