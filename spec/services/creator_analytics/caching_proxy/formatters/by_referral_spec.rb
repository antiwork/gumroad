# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::CachingProxy::Formatters::ByReferral do
  before do
    @user = create(:user)
    @dates = (Date.new(2021, 1, 1) .. Date.new(2021, 1, 5)).to_a
    create(:purchase, link: create(:product, user: @user), created_at: Date.new(2020, 8, 15))
    @service = CreatorAnalytics::CachingProxy.new(@user)
  end

  describe "#merge_data_by_referral" do
    it "fills sparse referral series without allocating for every absent day and referrer" do
      dates = (Date.new(2021, 1, 1) .. Date.new(2021, 12, 31)).to_a
      days_data = dates.each_with_index.map do |date, index|
        {
          dates_and_months: D3.date_month_domain([date]),
          by_referral: %i[views sales totals].index_with do
            { "product" => { "source-#{index % 20}.example.com" => [index + 1] } }
          end
        }.with_indifferent_access
      end
      original = Marshal.dump(days_data)
      @service.merge_data_by_referral(days_data, dates)

      allocated_before = GC.stat(:total_allocated_objects)
      result = @service.merge_data_by_referral(days_data, dates)
      allocations = GC.stat(:total_allocated_objects) - allocated_before

      expect(allocations).to be < 100_000
      %i[views sales totals].each do |type|
        expect(result[:by_referral][type]["product"]).to eq(
          20.times.to_h do |referrer|
            ["source-#{referrer}.example.com", dates.each_index.map { |index| index % 20 == referrer ? index + 1 : 0 }]
          end
        )
      end
      expect(Marshal.dump(days_data)).to eq(original)
    end

    it "preserves zeros and empty products for missing cached types and nil referral values" do
      days_data = [
        { by_referral: { views: { "product" => { "direct" => [2], "empty" => nil }, "empty-product" => nil } } },
        { by_referral: { sales: { "product" => { "direct" => [1] } } } }
      ].map.with_index do |data, index|
        data.merge(dates_and_months: D3.date_month_domain([@dates[index]])).with_indifferent_access
      end

      result = @service.merge_data_by_referral(days_data, @dates.first(2))

      expect(result[:by_referral]).to eq(
        views: { "product" => { "direct" => [2, 0], "empty" => [0, 0] }, "empty-product" => {} },
        sales: { "product" => { "direct" => [0, 1] }, "empty-product" => {} },
        totals: { "product" => {}, "empty-product" => {} }
      )
    end

    it "returns data merged by referral" do
      # notable: without `product` & `profile` and with an array for values for different days
      day_one = {
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] },
            "EpUED" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] },
            "EpUED" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] }
          },
          totals: {
            "tPsrl" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] },
            "EpUED" => { "direct" => [1], "Twitter" => [1], "Facebook" => [1] }
          }
        },
        dates_and_months: [
          { date: "Friday, January 1st", month: "January 2021", month_index: 0 },
        ]
      }
      # notable: 2 days fetched + new product
      day_two_and_three = {
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          }
        },
        dates_and_months: [
          { date: "Saturday, January 2nd", month: "January 2021", month_index: 0 },
          { date: "Sunday, January 3rd", month: "January 2021", month_index: 0 },
        ]
      }
      # notable: 2 more days fetched + new product
      day_four_and_five = {
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "Mmwrc" => { "direct" => [1, 1], "Twitter" => [1, 1] }
          }
        },
        dates_and_months: [
          { date: "Monday, January 4th", month: "January 2021", month_index: 0 },
          { date: "Tuesday, January 5th", month: "January 2021", month_index: 0 },
        ]
      }


      expect(@service.merge_data_by_referral([day_one, day_two_and_three, day_four_and_five], @dates)).to equal_with_indifferent_access(
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "EpUED" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "Mmwrc" => { "direct" => [0, 1, 1, 1, 1], "Twitter" => [0, 1, 1, 1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "EpUED" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "Mmwrc" => { "direct" => [0, 1, 1, 1, 1], "Twitter" => [0, 1, 1, 1, 1] }
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "EpUED" => { "direct" => [1, 1, 1, 1, 1], "Twitter" => [1, 1, 1, 1, 1], "Facebook" => [1, 0, 0, 0, 0] },
            "Mmwrc" => { "direct" => [0, 1, 1, 1, 1], "Twitter" => [0, 1, 1, 1, 1] }
          }
        },
        dates_and_months: [
          { date: "Friday, January 1st", month: "January 2021", month_index: 0 },
          { date: "Saturday, January 2nd", month: "January 2021", month_index: 0 },
          { date: "Sunday, January 3rd", month: "January 2021", month_index: 0 },
          { date: "Monday, January 4th", month: "January 2021", month_index: 0 },
          { date: "Tuesday, January 5th", month: "January 2021", month_index: 0 },
        ],
        start_date: "Jan  1, 2021",
        end_date: "Jan  5, 2021",
        first_sale_date: "Aug 14, 2020"
      )
    end
  end

  describe "#group_referral_data_by_day" do
    it "reformats the data by day" do
      data = {
        dates_and_months: [
          { date: "Friday, January 1st", month: "January 2021", month_index: 0 },
          { date: "Saturday, January 2nd", month: "January 2021", month_index: 0 }
        ],
        start_date: "Jan  1, 2021",
        end_date: "Jan  7, 2021",
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "Google" => [1, 1], "Facebook" => [1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          }
        },
        first_sale_date: "Aug 14, 2020"
      }

      expect(@service).to receive(:dates_and_months_to_days).with(data[:dates_and_months], without_years: nil).and_call_original
      expect(@service.group_referral_data_by_day(data)).to equal_with_indifferent_access(
        dates: [
          "Friday, January 1st 2021",
          "Saturday, January 2nd 2021"
        ],
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "Google" => [1, 1], "Facebook" => [1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          }
        }
      )

      expect(@service).to receive(:dates_and_months_to_days).with(data[:dates_and_months], without_years: true).and_call_original
      expect(@service.group_referral_data_by_day(data, days_without_years: true)).to equal_with_indifferent_access(
        dates: [
          "Friday, January 1st",
          "Saturday, January 2nd"
        ],
        by_referral: {
          views: {
            "tPsrl" => { "direct" => [1, 1], "Twitter" => [1, 1] },
            "EpUED" => { "Google" => [1, 1], "Facebook" => [1, 1] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1], "Tiktok" => [1, 1] },
            "EpUED" => {}
          }
        }
      )
    end
  end

  describe "#group_referral_data_by_month" do
    it "reformats the data by month" do
      data = {
        dates_and_months: [
          { date: "Saturday, July 31st", month: "July 2021", month_index: 0 },
          { date: "Sunday, August 1st", month: "August 2021", month_index: 1 },
          { date: "Monday, August 2nd", month: "August 2021", month_index: 1 }
        ],
        start_date: "July 31, 2021",
        end_date: "August 2, 2021",
        by_referral: {
          views: {
            "EpUED" => { "Google" => [1, 1, 1], "Facebook" => [1, 1, 1] },
          },
          sales: {
            "tPsrl" => { "direct" => [1, 1, 1], "Tiktok" => [1, 1, 1] },
          },
          totals: {
            "tPsrl" => { "direct" => [1, 1, 1], "Tiktok" => [1, 1, 1] },
          }
        },
        first_sale_date: "Aug 14, 2020"
      }

      expect(@service).to receive(:dates_and_months_to_months).and_call_original
      expect(@service.group_referral_data_by_month(data)).to equal_with_indifferent_access(
        dates: [
          "July 2021",
          "August 2021"
        ],
        by_referral: {
          views: {
            "EpUED" => { "Google" => [1, 2], "Facebook" => [1, 2] }
          },
          sales: {
            "tPsrl" => { "direct" => [1, 2], "Tiktok" => [1, 2] }
          },
          totals: {
            "tPsrl" => { "direct" => [1, 2], "Tiktok" => [1, 2] }
          }
        }
      )
    end
  end
end
