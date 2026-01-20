# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  let(:seller) { create(:user, timezone: "UTC", created_at: Time.utc(2020, 1, 1)) }
  let(:product1) { create(:product, :is_subscription, user: seller, name: "Product Alpha") }
  let(:product2) { create(:product, :is_subscription, user: seller, name: "Product Beta") }
  let(:service) { described_class.new(seller:) }

  # Create purchases with early dates to ensure earliest_analytics_date is set correctly
  let!(:purchase1) { create(:purchase, link: product1, created_at: Date.new(2020, 1, 1).to_time) }
  let!(:purchase2) { create(:purchase, link: product2, created_at: Date.new(2020, 1, 1).to_time) }

  describe "#generate_data" do
    let(:start_date) { Date.new(2020, 1, 15) }
    let(:end_date) { Date.new(2020, 1, 20) }

    before do
      fetcher_double = instance_double(CreatorAnalytics::Churn::ElasticsearchFetcher)
      allow(fetcher_double).to receive(:churn_events).and_return({})
      allow(fetcher_double).to receive(:new_subscriptions).and_return({})
      allow(fetcher_double).to receive(:initial_active_counts).and_return({})
      allow(CreatorAnalytics::Churn::ElasticsearchFetcher).to receive(:new).and_return(fetcher_double)
    end

    it "returns structure with metadata and data for current period" do
      result = service.generate_data(start_date:, end_date:)

      expect(result).to have_key(:metadata)
      expect(result).to have_key(:data)
      expect(result[:metadata]).to have_key(:current_period)
      expect(result[:metadata]).to have_key(:products)
      expect(result[:data]).to have_key(:current_period)
    end

    it "includes current period metadata with date range" do
      result = service.generate_data(start_date:, end_date:)

      expect(result[:metadata][:current_period]).to include(
        start_date: "2020-01-15",
        end_date: "2020-01-20"
      )
    end

    it "includes product info in metadata" do
      result = service.generate_data(start_date:, end_date:)

      expect(result[:metadata][:products]).to be_an(Array)
      expect(result[:metadata][:products].length).to eq(2)
      product_info = result[:metadata][:products].find { |p| p[:name] == "Product Alpha" }
      expect(product_info).to include(
        external_id: product1.external_id,
        permalink: product1.unique_permalink,
        name: "Product Alpha"
      )
    end

    it "includes current period data with daily, monthly, and summary" do
      result = service.generate_data(start_date:, end_date:)

      current_data = result[:data][:current_period]
      expect(current_data).to have_key(:daily)
      expect(current_data).to have_key(:monthly)
      expect(current_data).to have_key(:summary)
    end

    context "when previous period can be built" do
      let(:start_date) { Date.new(2020, 2, 15) }
      let(:end_date) { Date.new(2020, 2, 20) }

      it "includes previous period metadata and data" do
        result = service.generate_data(start_date:, end_date:)

        expect(result[:metadata][:previous_period]).to be_present
        expect(result[:data][:previous_period]).to be_present
      end

      it "calculates previous period with same length as current period" do
        result = service.generate_data(start_date:, end_date:)

        current_period = result[:metadata][:current_period]
        previous_period = result[:metadata][:previous_period]

        current_length = (Date.parse(current_period[:end_date]) - Date.parse(current_period[:start_date])).to_i + 1
        previous_length = (Date.parse(previous_period[:end_date]) - Date.parse(previous_period[:start_date])).to_i + 1

        expect(previous_length).to eq(current_length)
      end

      it "sets previous period end date to one day before current period start" do
        result = service.generate_data(start_date:, end_date:)

        current_start = Date.parse(result[:metadata][:current_period][:start_date])
        previous_end = Date.parse(result[:metadata][:previous_period][:end_date])

        expect(previous_end).to eq(current_start - 1.day)
      end
    end

    context "when previous period cannot be built" do
      let(:start_date) { Date.new(2020, 1, 1) }
      let(:end_date) { Date.new(2020, 1, 5) }

      it "returns nil for previous period" do
        result = service.generate_data(start_date:, end_date:)

        expect(result[:metadata][:previous_period]).to be_nil
        expect(result[:data][:previous_period]).to be_nil
      end
    end

    context "with caching" do
      let(:cached_seller) { create(:user, timezone: "UTC", created_at: Time.utc(2020, 1, 1)) }
      let(:cached_product) { create(:product, :is_subscription, user: cached_seller) }
      let!(:cached_purchase) { create(:purchase, link: cached_product, created_at: Date.new(2020, 1, 1).to_time) }
      let!(:large_seller_record) { create(:large_seller, user: cached_seller) }
      let(:cached_service) { described_class.new(seller: cached_seller) }
      let(:cached_start_date) { Date.new(2020, 1, 1) }
      let(:cached_end_date) { Date.new(2020, 1, 5) }

      before do
        # Mock ElasticsearchFetcher for cached seller
        fetcher_double = instance_double(CreatorAnalytics::Churn::ElasticsearchFetcher)
        allow(fetcher_double).to receive(:churn_events).and_return({})
        allow(fetcher_double).to receive(:new_subscriptions).and_return({})
        allow(fetcher_double).to receive(:initial_active_counts).and_return({})
        allow(CreatorAnalytics::Churn::ElasticsearchFetcher).to receive(:new).and_return(fetcher_double)
      end

      around do |example|
        travel_to Time.utc(2020, 1, 10) do
          example.run
        end
      end

      it "reads from cache when cacheable range exists" do
        cached_payload = {
          metadata: { current_period: { start_date: "2020-01-01", end_date: "2020-01-05" }, products: [] },
          data: { current_period: { daily: {}, monthly: {}, summary: {} } }
        }
        date_window = CreatorAnalytics::Churn::DateWindow.new(
          seller: cached_seller,
          product_scope: CreatorAnalytics::Churn::ProductScope.new(seller: cached_seller),
          start_date: cached_start_date,
          end_date: cached_end_date
        )
        cache_key = cached_service.send(:cache_key_for, date_window)
        ComputedSalesAnalyticsDay.upsert_data_from_key(cache_key, cached_payload)

        result = cached_service.generate_data(start_date: cached_start_date, end_date: cached_end_date)

        expect(result).to eq(cached_payload.deep_symbolize_keys)
      end

      it "writes to cache after computing cacheable range" do
        result = cached_service.generate_data(start_date: cached_start_date, end_date: cached_end_date)

        date_window = CreatorAnalytics::Churn::DateWindow.new(
          seller: cached_seller,
          product_scope: CreatorAnalytics::Churn::ProductScope.new(seller: cached_seller),
          start_date: cached_start_date,
          end_date: cached_end_date
        )
        cache_key = cached_service.send(:cache_key_for, date_window)
        cached_record = ComputedSalesAnalyticsDay.find_by(key: cache_key)

        expect(cached_record).to be_present
        expect(cached_record.data).to be_present

        cached_data = JSON.parse(cached_record.data)
        result_as_json = JSON.parse(JSON.generate(result))

        # Check top-level keys
        expect(cached_data.keys).to match_array(result_as_json.keys)
        expect(cached_data).to have_key("metadata")
        expect(cached_data).to have_key("data")

        # Check metadata structure
        expect(cached_data["metadata"]).to have_key("current_period")
        expect(cached_data["metadata"]).to have_key("products")
        expect(cached_data["metadata"]["current_period"]).to eq(result_as_json["metadata"]["current_period"])

        # Check data structure
        expect(cached_data["data"]).to have_key("current_period")
        current_period_cached = cached_data["data"]["current_period"]
        current_period_result = result_as_json["data"]["current_period"]

        expect(current_period_cached).to have_key("daily")
        expect(current_period_cached).to have_key("monthly")
        expect(current_period_cached).to have_key("summary")

        # Check daily keys
        expect(current_period_cached["daily"].keys).to match_array(current_period_result["daily"].keys)

        # Check monthly keys
        expect(current_period_cached["monthly"].keys).to match_array(current_period_result["monthly"].keys)

        # Check summary structure
        expect(current_period_cached["summary"]).to have_key("total")
        expect(current_period_cached["summary"]).to have_key("by_product")
        expect(current_period_cached["summary"]["by_product"].keys).to match_array(current_period_result["summary"]["by_product"].keys)

        # Compare current_period structure
        expect(current_period_cached).to eq(current_period_result)

        # Final full comparison
        expect(cached_data).to eq(result_as_json)
      end

      it "does not cache recent dates (within 2 days)" do
        recent_start = Date.new(2020, 1, 9)
        recent_end = Date.new(2020, 1, 10)

        cached_service.generate_data(start_date: recent_start, end_date: recent_end)

        date_window = CreatorAnalytics::Churn::DateWindow.new(
          seller: cached_seller,
          product_scope: CreatorAnalytics::Churn::ProductScope.new(seller: cached_seller),
          start_date: recent_start,
          end_date: recent_end
        )
        cache_key = cached_service.send(:cache_key_for, date_window)
        cached_record = ComputedSalesAnalyticsDay.find_by(key: cache_key)
        expect(cached_record).to be_nil
      end
    end

    context "without caching" do
      it "does not use cache for regular sellers" do
        result = service.generate_data(start_date:, end_date:)

        expect(result).to have_key(:data)
        expect(result[:data][:current_period]).to be_present
      end

      it "does not write to cache for regular sellers" do
        service.generate_data(start_date:, end_date:)

        cache_key = service.send(:cache_key_for, instance_double(CreatorAnalytics::Churn::DateWindow, start_date:, end_date:))
        cached_record = ComputedSalesAnalyticsDay.find_by(key: cache_key)
        expect(cached_record).to be_nil
      end
    end

    context "with actual churn data" do
      let(:churn_events) do
        {
          [product1.id, Date.new(2020, 1, 15)] => { churned_count: 2, revenue_lost_cents: 5000 }
        }
      end
      let(:new_subscriptions) do
        {
          [product1.id, Date.new(2020, 1, 15)] => 5
        }
      end
      let(:initial_active_counts) { { product1.id => 10 } }

      before do
        fetcher_double = instance_double(CreatorAnalytics::Churn::ElasticsearchFetcher)
        allow(fetcher_double).to receive(:churn_events).and_return(churn_events)
        allow(fetcher_double).to receive(:new_subscriptions).and_return(new_subscriptions)
        allow(fetcher_double).to receive(:initial_active_counts).and_return(initial_active_counts)
        allow(CreatorAnalytics::Churn::ElasticsearchFetcher).to receive(:new).and_return(fetcher_double)
      end

      it "includes churn data in current period" do
        result = service.generate_data(start_date:, end_date:)

        day1 = result[:data][:current_period][:daily]["2020-01-15"]
        expect(day1[:by_product][product1.unique_permalink]).to include(
          churned_customers_count: 2,
          revenue_lost_cents: 5000
        )
      end
    end

    context "with invalid date range" do
      it "clamps end_date to start_date when start_date is after end_date" do
        # DateWindow clamps dates rather than raising errors
        result = service.generate_data(start_date: Date.new(2020, 1, 20), end_date: Date.new(2020, 1, 15))

        expect(result[:metadata][:current_period][:start_date]).to eq("2020-01-20")
        expect(result[:metadata][:current_period][:end_date]).to eq("2020-01-20")
      end
    end
  end
end
