# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::CachingProxy::Formatters::ByDate do
  before do
    @service = CreatorAnalytics::CachingProxy.new(build(:user))
  end

  describe "#merge_data_by_date" do
    it "returns data merged by date" do
      day_one = {
        dates_and_months: [{ date: "Tuesday, June 30th", month: "June 2020", month_index: 0 }],
        start_date: "June 30, 2020",
        end_date: "June 30, 2020",
        by_date: {
          views: { "tPsrl" => [1], "PruAb" => [1] },
          sales: { "tPsrl" => [1], "PruAb" => [1] },
          totals: { "tPsrl" => [1], "PruAb" => [1] }
        },
        first_sale_date: "Apr 10, 2019"
      }
      # notable: 2 days fetched + new product + product deleted
      day_two_and_three = {
        dates_and_months: [
          { date: "Wednesday, July 1st", month: "July 2020", month_index: 0 },
          { date: "Thursday, July 2nd", month: "July 2020", month_index: 0 }
        ],
        start_date: "July 1, 2020",
        end_date: "July 2, 2020",
        by_date: {
          views: { "tPsrl" => [1, 1], "Mmwrc" => [1, 1] },
          sales: { "tPsrl" => [1, 1], "Mmwrc" => [1, 1] },
          totals: { "tPsrl" => [1, 1], "Mmwrc" => [1, 1] }
        },
        first_sale_date: "Apr 10, 2019"
      }

      expect(@service).to receive(:rebuild_month_index_values!).and_call_original
      expect(@service.merge_data_by_date([day_one, day_two_and_three])).to equal_with_indifferent_access(
        dates_and_months: [
          { date: "Tuesday, June 30th", month: "June 2020", month_index: 0 },
          { date: "Wednesday, July 1st", month: "July 2020", month_index: 1 },
          { date: "Thursday, July 2nd", month: "July 2020", month_index: 1 },
        ],
        by_date: {
          views: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 0, 0], "Mmwrc" => [0, 1, 1] },
          sales: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 0, 0], "Mmwrc" => [0, 1, 1] },
          totals: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 0, 0], "Mmwrc" => [0, 1, 1] },
        },
        start_date: "June 30, 2020",
        end_date: "July 2, 2020",
        first_sale_date: "Apr 10, 2019",
      )
    end
  end

  describe "#group_date_data_by_day" do
    it "reformats the data by day" do
      data = {
        dates_and_months: [
          { date: "Friday, July 3rd", month: "July 2020", month_index: 0 },
          { date: "Saturday, July 4th", month: "July 2020", month_index: 0 }
        ],
        start_date: "July 3, 2020",
        end_date: "July 4, 2020",
        by_date: {
          views: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          sales: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          totals: { "tPsrl" => [1, 1], "PruAb" => [1, 1] }
        },
        first_sale_date: "Apr 10, 2019"
      }

      expect(@service).to receive(:dates_and_months_to_days).with(data[:dates_and_months], without_years: nil).and_call_original
      expect(@service.group_date_data_by_day(data)).to equal_with_indifferent_access(
        dates: [
          "Friday, July 3rd 2020",
          "Saturday, July 4th 2020"
        ],
        by_date: {
          views: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          sales: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          totals: { "tPsrl" => [1, 1], "PruAb" => [1, 1] }
        }
      )

      expect(@service).to receive(:dates_and_months_to_days).with(data[:dates_and_months], without_years: true).and_call_original
      expect(@service.group_date_data_by_day(data, days_without_years: true)).to equal_with_indifferent_access(
        dates: [
          "Friday, July 3rd",
          "Saturday, July 4th"
        ],
        by_date: {
          views: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          sales: { "tPsrl" => [1, 1], "PruAb" => [1, 1] },
          totals: { "tPsrl" => [1, 1], "PruAb" => [1, 1] }
        }
      )
    end
  end

  describe "#group_date_data_by_month" do
    it "reformats the data by month" do
      data = {
        dates_and_months: [
          { date: "Saturday, July 31st", month: "July 2021", month_index: 0 },
          { date: "Sunday, August 1st", month: "August 2021", month_index: 1 },
          { date: "Monday, August 2nd", month: "August 2021", month_index: 1 },
        ],
        start_date: "July 31, 2021",
        end_date: "August 2, 2021",
        by_date: {
          views: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 1, 1] },
          sales: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 1, 1] },
          totals: { "tPsrl" => [1, 1, 1], "PruAb" => [1, 1, 1] }
        },
        first_sale_date: "Apr 10, 2019"
      }

      expect(@service).to receive(:dates_and_months_to_months).and_call_original
      expect(@service.group_date_data_by_month(data)).to equal_with_indifferent_access(
        dates: [
          "July 2021",
          "August 2021"
        ],
        by_date: {
          views: { "tPsrl" => [1, 2], "PruAb" => [1, 2] },
          sales: { "tPsrl" => [1, 2], "PruAb" => [1, 2] },
          totals: { "tPsrl" => [1, 2], "PruAb" => [1, 2] }
        }
      )
    end
  end
end
