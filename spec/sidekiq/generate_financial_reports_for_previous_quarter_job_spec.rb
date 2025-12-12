# frozen_string_literal: true

require "spec_helper"

describe GenerateFinancialReportsForPreviousQuarterJob do
  describe ".perform" do
    it "does not generate any reports when the Rails environment is not production" do
      described_class.new.perform

      expect(CreateVatReportJob.jobs.size).to eq(0)
      expect(GenerateSalesReportJob.jobs.size).to eq(0)
    end

    it "generates reports when the Rails environment is production" do
      allow(Rails.env).to receive(:production?).and_return(true)

      described_class.new.perform

      expect(CreateVatReportJob).to have_enqueued_sidekiq_job(an_instance_of(Integer), an_instance_of(Integer))

      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job("GB", an_instance_of(String), an_instance_of(String), GenerateSalesReportJob::ALL_SALES)
      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job("AU", an_instance_of(String), an_instance_of(String), GenerateSalesReportJob::ALL_SALES)
      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job("SG", an_instance_of(String), an_instance_of(String), GenerateSalesReportJob::ALL_SALES)
      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job("NO", an_instance_of(String), an_instance_of(String), GenerateSalesReportJob::ALL_SALES)
    end

    [[2017,  1, 2016, 4],
     [2017,  2, 2016, 4],
     [2017,  3, 2016, 4],
     [2017,  4, 2017, 1],
     [2017,  5, 2017, 1],
     [2017,  6, 2017, 1],
     [2017,  7, 2017, 2],
     [2017, 10, 2017, 3]].each do |current_year, current_month, expected_year, expected_quarter|
      it "sets the quarter and year correctly for year #{current_year} and month #{current_month}" do
        allow(Rails.env).to receive(:production?).and_return(true)

        travel_to(Time.current.change(year: current_year, month: current_month, day: 2)) do
          described_class.new.perform
        end

        expect(CreateVatReportJob).to have_enqueued_sidekiq_job(expected_quarter, expected_year)
      end
    end
  end
end
