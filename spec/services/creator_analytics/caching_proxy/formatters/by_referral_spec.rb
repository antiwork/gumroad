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

      # Proxy only: exhaustive union merge allocates ~159k on this fixture; sparse stays ~2k.
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

    it "matches the exhaustive-union merge byte-for-byte on deterministic sparse payloads" do
      rng = Random.new(2464)
      32.times do
        date_count = rng.rand(2..8)
        dates = date_count.times.map { |i| Date.new(2021, 1, 1) + i }
        chunk_spans = []
        remaining = date_count
        while remaining.positive?
          span = [rng.rand(1..3), remaining].min
          chunk_spans << span
          remaining -= span
        end

        offset = 0
        days_data = chunk_spans.map do |span|
          chunk_dates = dates[offset, span]
          offset += span
          products = Array.new(rng.rand(1..3)) { |i| "p#{i}" }
          by_referral = {}
          %i[views sales totals].each do |type|
            next if rng.rand < 0.15

            by_referral[type] = products.each_with_object({}) do |permalink, memo|
              if rng.rand < 0.1
                memo[permalink] = nil
                next
              end
              referrers = Array.new(rng.rand(0..3)) { |i| "ref-#{i}" }
              memo[permalink] = referrers.index_with do |referrer|
                rng.rand < 0.1 ? nil : Array.new(span) { rng.rand(0..5) }
              end
            end
          end
          {
            dates_and_months: D3.date_month_domain(chunk_dates),
            by_referral: by_referral
          }.with_indifferent_access
        end

        expected = exhaustive_union_merge_by_referral(days_data, dates)
        actual = @service.merge_data_by_referral(days_data, dates)
        expect(actual[:by_referral].as_json.to_json).to eq(expected.as_json.to_json)
      end
    end

    it "copies a length-mismatched chunk the same way range assignment did" do
      days_data = [
        {
          dates_and_months: D3.date_month_domain(@dates.first(2)),
          by_referral: {
            views: { "product" => { "short" => [9], "long" => [1, 2, 3] } },
            sales: {},
            totals: {}
          }
        }.with_indifferent_access
      ]

      expected = exhaustive_union_merge_by_referral(days_data, @dates.first(2))
      actual = @service.merge_data_by_referral(days_data, @dates.first(2))

      expect(actual[:by_referral].as_json.to_json).to eq(expected.as_json.to_json)
      expect(actual[:by_referral][:views]["product"]["short"]).to eq([9])
      expect(actual[:by_referral][:views]["product"]["long"]).to eq([1, 2, 3])
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

  # Mirrors pre-PR exhaustive day*product*referrer union merge for equivalence asserts.
  def exhaustive_union_merge_by_referral(days_data, dates)
    data = { views: {}, sales: {}, totals: {} }

    permalinks = days_data.flat_map do |day_data|
      day_data[:by_referral].values.compact.map { |products| products.keys }
    end.flatten.uniq

    referrers = {}
    %i[views sales totals].each do |type|
      referrers[type] = {}
      permalinks.each do |permalink|
        referrers[type][permalink] = []
        days_data.each do |day_data|
          referrers[type][permalink] += day_data.dig(:by_referral, type, permalink)&.keys || []
        end
        referrers[type][permalink].uniq!
      end
    end

    permalinks.each do |permalink|
      total_day_index = 0
      days_data.each do |day_data|
        days_count = day_data[:dates_and_months].size
        %i[views sales totals].each do |type|
          data[type][permalink] ||= {}
          referrers[type][permalink].each do |referrer|
            data[type][permalink][referrer] ||= [0] * dates.size
            values = day_data.dig(:by_referral, type, permalink, referrer) || ([0] * days_count)
            data[type][permalink][referrer][total_day_index, days_count] = values
          end
        end
        total_day_index += days_count
      end
    end

    data
  end
end
