# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn::DatasetBuilder do
  let(:seller) { create(:user, timezone: "UTC", created_at: Time.utc(2020, 1, 1)) }
  let(:product1) { create(:product, :is_subscription, user: seller, name: "Product Alpha") }
  let(:product2) { create(:product, :is_subscription, user: seller, name: "Product Beta") }
  let(:start_date) { Date.new(2020, 1, 15) }
  let(:end_date) { Date.new(2020, 1, 20) }

  def product_zero_stats_hash
    { churn_rate: 0.0, churned_customers_count: 0, revenue_lost_cents: 0, subscriber_base: 0 }
  end

  # Create purchases with early dates to ensure earliest_analytics_date is set correctly
  let!(:purchase1) { create(:purchase, link: product1, created_at: Date.new(2020, 1, 1).to_time) }
  let!(:purchase2) { create(:purchase, link: product2, created_at: Date.new(2020, 1, 1).to_time) }

  let(:product_scope) { CreatorAnalytics::Churn::ProductScope.new(seller:) }
  let(:date_window) do
    CreatorAnalytics::Churn::DateWindow.new(
      seller:,
      product_scope:,
      start_date:,
      end_date:
    )
  end
  let(:churn_events) { {} }
  let(:new_subscriptions) { {} }
  let(:initial_active_counts) { {} }
  let(:service) do
    described_class.new(
      product_scope:,
      date_window:,
      churn_events:,
      new_subscriptions:,
      initial_active_counts:
    )
  end

  describe "#build" do
    context "with empty data" do
      it "returns structure with empty daily, monthly, and summary data" do
        result = service.build

        expect(result).to have_key(:metadata)
        expect(result).to have_key(:data)
        expect(result[:data]).to have_key(:daily)
        expect(result[:data]).to have_key(:monthly)
        expect(result[:data]).to have_key(:summary)

        expect(result[:data][:daily]).to be_a(Hash)
        expect(result[:data][:monthly]).to be_a(Hash)
        expect(result[:data][:summary]).to have_key(:total)
        expect(result[:data][:summary]).to have_key(:by_product)

        date_window.daily_dates.each do |date|
          day_key = date.to_s
          daily_entry = result[:data][:daily][day_key]
          expect(daily_entry).to have_key(:by_product)
          expect(daily_entry).to have_key(:total)
          expect(daily_entry[:total]).to eq(product_zero_stats_hash)
          daily_entry[:by_product].each_value do |product_stats|
            expect(product_stats).to eq(product_zero_stats_hash)
          end
        end

        date_window.monthly_dates.each do |month_date|
          month_key = month_date.to_s
          monthly_entry = result[:data][:monthly][month_key]
          expect(monthly_entry).to have_key(:by_product)
          expect(monthly_entry).to have_key(:total)
          expect(monthly_entry[:total]).to eq(product_zero_stats_hash)
          monthly_entry[:by_product].each_value do |product_stats|
            expect(product_stats).to eq(product_zero_stats_hash)
          end
        end

        expect(result[:data][:summary][:total]).to eq(product_zero_stats_hash)
        expect(result[:data][:summary][:by_product]).to be_a(Hash)

        result[:data][:summary][:by_product].each_value do |product_stats|
          expect(product_stats).to eq(product_zero_stats_hash)
        end
      end

      it "includes metadata with date range and products" do
        result = service.build

        expect(result[:metadata][:start_date]).to eq("2020-01-15")
        expect(result[:metadata][:end_date]).to eq("2020-01-20")
        expect(result[:metadata][:products]).to be_an(Array)
        expect(result[:metadata][:products].length).to eq(2)
      end

      it "includes product info in metadata" do
        result = service.build

        product_info = result[:metadata][:products].find { |p| p[:name] == "Product Alpha" }
        expect(product_info).to include(
          external_id: product1.external_id,
          permalink: product1.unique_permalink,
          name: "Product Alpha"
        )
      end

      it "returns zero stats for all daily entries" do
        result = service.build

        date_window.daily_dates.each do |date|
          day_key = date.to_s
          expect(result[:data][:daily][day_key]).to have_key(:total)
          expect(result[:data][:daily][day_key][:total]).to eq(product_zero_stats_hash)
        end
      end
    end

    context "with churn events and new subscriptions" do
      let(:churn_events) do
        {
          [product1.id, Date.new(2020, 1, 15)] => { churned_count: 2, revenue_lost_cents: 5000 },
          [product1.id, Date.new(2020, 1, 16)] => { churned_count: 1, revenue_lost_cents: 3000 },
          [product2.id, Date.new(2020, 1, 15)] => { churned_count: 3, revenue_lost_cents: 7500 }
        }
      end
      let(:new_subscriptions) do
        {
          [product1.id, Date.new(2020, 1, 15)] => 5,
          [product1.id, Date.new(2020, 1, 16)] => 3,
          [product2.id, Date.new(2020, 1, 15)] => 2
        }
      end
      let(:initial_active_counts) do
        {
          product1.id => 10,
          product2.id => 5
        }
      end

      it "calculates daily churn rates correctly" do
        result = service.build

        # Day 1: product1: (2 churned / (10 active + 5 new)) * 100 = 13.33%
        day1 = result[:data][:daily]["2020-01-15"]
        expect(day1[:by_product][product1.unique_permalink]).to include(
          churn_rate: 13.33,
          churned_customers_count: 2,
          revenue_lost_cents: 5000,
          subscriber_base: 15
        )

        # Day 1: product2: (3 churned / (5 active + 2 new)) * 100 = 42.86%
        expect(day1[:by_product][product2.unique_permalink]).to include(
          churn_rate: 42.86,
          churned_customers_count: 3,
          revenue_lost_cents: 7500,
          subscriber_base: 7
        )

        # Day 1 total: (5 churned / 22 total) * 100 = 22.73%
        expect(day1[:total]).to include(
          churn_rate: 22.73,
          churned_customers_count: 5,
          revenue_lost_cents: 12500,
          subscriber_base: 22
        )
      end

      it "tracks running active counts across days" do
        result = service.build

        # Day 1: product1 starts with 10, gets 5 new, loses 2 = 13 active
        # Day 2: product1 starts with 13, gets 3 new, loses 1 = 15 active
        day2 = result[:data][:daily]["2020-01-16"]
        expect(day2[:by_product][product1.unique_permalink]).to include(
          subscriber_base: 16 # 13 active + 3 new
        )
      end

      it "prevents negative active counts" do
        churn_events_with_overchurn = {
          [product1.id, Date.new(2020, 1, 15)] => { churned_count: 20, revenue_lost_cents: 50000 }
        }
        new_subscriptions_with_overchurn = {
          [product1.id, Date.new(2020, 1, 15)] => 5
        }
        initial_active_counts_with_overchurn = {
          product1.id => 10
        }

        service = described_class.new(
          product_scope:,
          date_window:,
          churn_events: churn_events_with_overchurn,
          new_subscriptions: new_subscriptions_with_overchurn,
          initial_active_counts: initial_active_counts_with_overchurn
        )

        result = service.build
        day2 = result[:data][:daily]["2020-01-16"]

        # Active count should not go negative
        expect(day2[:by_product][product1.unique_permalink][:subscriber_base]).to be >= 0
      end

      it "calculates monthly aggregates correctly" do
        result = service.build

        # January 2020 should aggregate all days in the range
        january = result[:data][:monthly]["2020-01-01"]
        expect(january).to have_key(:by_product)
        expect(january).to have_key(:total)

        # Monthly product1: active_start=10, new=8, churned=3
        product1_monthly = january[:by_product][product1.unique_permalink]
        expect(product1_monthly[:subscriber_base]).to eq(18) # 10 + 8
        expect(product1_monthly[:churned_customers_count]).to eq(3)
        expect(product1_monthly[:churn_rate]).to eq(16.67) # (3/18) * 100

        # Monthly total
        expect(january[:total][:subscriber_base]).to eq(25) # product1: 18, product2: 7
        expect(january[:total][:churned_customers_count]).to eq(6)
      end

      it "uses Stripe formula: (churned / (active_base + new_subscribers)) * 100" do
        result = service.build

        day1 = result[:data][:daily]["2020-01-15"]
        product1_day1 = day1[:by_product][product1.unique_permalink]

        # (2 churned / (10 active + 5 new)) * 100 = 13.33%
        active_base = 10
        new_subscribers = 5
        churned = 2
        expected_rate = ((churned.to_f / (active_base + new_subscribers)) * 100).round(2)

        expect(product1_day1[:churn_rate]).to eq(expected_rate)
        expect(product1_day1[:subscriber_base]).to eq(active_base + new_subscribers)
      end

      it "sums monthly counts before calculating rate (not averaging daily percentages)" do
        # This test verifies monthly rates come from summed counts, not averaged daily rates
        # If we averaged daily rates: Day 1: 13.33%, Day 2: 6.25% -> average = 9.79%
        # But Stripe formula: (3 churned / (10 + 8 new)) * 100 = 16.67%
        result = service.build

        january = result[:data][:monthly]["2020-01-01"]
        product1_monthly = january[:by_product][product1.unique_permalink]

        # Verify it's using summed counts, not averaged percentages
        total_churned = 3 # Sum of day1 (2) + day2 (1)
        total_subscriber_base = 18 # active_start (10) + new (8)
        expected_rate = ((total_churned.to_f / total_subscriber_base) * 100).round(2)

        expect(product1_monthly[:churn_rate]).to eq(expected_rate)
        expect(product1_monthly[:churn_rate]).not_to eq(9.79) # Would be if we averaged daily rates
      end

      it "calculates summary totals correctly" do
        result = service.build

        summary = result[:data][:summary]

        # Product1 summary: active_start=10, new=8, churned=3
        product1_summary = summary[:by_product][product1.unique_permalink]
        expect(product1_summary[:subscriber_base]).to eq(18)
        expect(product1_summary[:churned_customers_count]).to eq(3)
        expect(product1_summary[:revenue_lost_cents]).to eq(8000)
        expect(product1_summary[:churn_rate]).to eq(16.67)

        # Total summary
        expect(summary[:total][:subscriber_base]).to eq(25)
        expect(summary[:total][:churned_customers_count]).to eq(6)
        expect(summary[:total][:revenue_lost_cents]).to eq(15500)
        expect(summary[:total][:churn_rate]).to eq(24.0) # (6/25) * 100
      end

      it "handles products with no activity" do
        product3 = create(:product, :is_subscription, user: seller, name: "Product Gamma")
        create(:purchase, link: product3)

        result = service.build

        # Product3 should appear in metadata but have zero stats
        product3_info = result[:metadata][:products].find { |p| p[:name] == "Product Gamma" }
        expect(product3_info).to be_present

        # Product3 should have zero stats in summary
        product3_summary = result[:data][:summary][:by_product][product3.unique_permalink]
        expect(product3_summary).to eq(product_zero_stats_hash)
      end
    end

    context "with zero denominator" do
      let(:churn_events) do
        {
          [product1.id, Date.new(2020, 1, 15)] => { churned_count: 5, revenue_lost_cents: 10000 }
        }
      end
      let(:new_subscriptions) { {} }
      let(:initial_active_counts) { {} }

      it "returns zero churn rate when denominator is zero" do
        result = service.build

        day1 = result[:data][:daily]["2020-01-15"]
        expect(day1[:by_product][product1.unique_permalink][:churn_rate]).to eq(0.0)
        expect(day1[:total][:churn_rate]).to eq(0.0)
      end

      it "handles new subscriptions without churn" do
        new_subscriptions_without_churn = {
          [product1.id, Date.new(2020, 1, 15)] => 10
        }
        initial_active_without_churn = { product1.id => 5 }

        service = described_class.new(
          product_scope:,
          date_window:,
          churn_events: {},
          new_subscriptions: new_subscriptions_without_churn,
          initial_active_counts: initial_active_without_churn
        )

        result = service.build
        day1 = result[:data][:daily]["2020-01-15"]

        expect(day1[:by_product][product1.unique_permalink][:churn_rate]).to eq(0.0)
        expect(day1[:by_product][product1.unique_permalink][:subscriber_base]).to eq(15) # 5 + 10
      end
    end

    context "with multiple months" do
      let(:start_date) { Date.new(2020, 1, 15) }
      let(:end_date) { Date.new(2020, 2, 5) }
      let(:churn_events) do
        {
          [product1.id, Date.new(2020, 1, 20)] => { churned_count: 2, revenue_lost_cents: 5000 },
          [product1.id, Date.new(2020, 2, 1)] => { churned_count: 1, revenue_lost_cents: 3000 }
        }
      end
      let(:new_subscriptions) do
        {
          [product1.id, Date.new(2020, 1, 20)] => 5,
          [product1.id, Date.new(2020, 2, 1)] => 3
        }
      end
      let(:initial_active_counts) { { product1.id => 10 } }

      it "groups monthly data by month" do
        result = service.build

        expect(result[:data][:monthly]).to have_key("2020-01-01")
        expect(result[:data][:monthly]).to have_key("2020-02-01")

        january = result[:data][:monthly]["2020-01-01"]
        expect(january[:by_product][product1.unique_permalink][:churned_customers_count]).to eq(2)
        expect(january[:by_product][product1.unique_permalink][:subscriber_base]).to eq(15) # 10 active_start + 5 new

        february = result[:data][:monthly]["2020-02-01"]
        expect(february[:by_product][product1.unique_permalink][:churned_customers_count]).to eq(1)
        expect(february[:by_product][product1.unique_permalink][:subscriber_base]).to eq(16) # 13 active_start + 3 new
      end

      it "tracks subscriber_base per month correctly" do
        result = service.build

        january = result[:data][:monthly]["2020-01-01"]
        # January: 10 active_start + 5 new = 15 subscriber_base
        expect(january[:by_product][product1.unique_permalink][:subscriber_base]).to eq(15)

        february = result[:data][:monthly]["2020-02-01"]
        # February: 13 active_start (from end of Jan: 10 + 5 - 2) + 3 new = 16 subscriber_base
        expect(february[:by_product][product1.unique_permalink][:subscriber_base]).to eq(16)
      end
    end

    context "with rounding" do
      let(:churn_events) do
        {
          [product1.id, Date.new(2020, 1, 15)] => { churned_count: 1, revenue_lost_cents: 2000 }
        }
      end
      let(:new_subscriptions) do
        {
          [product1.id, Date.new(2020, 1, 15)] => 3
        }
      end
      let(:initial_active_counts) { { product1.id => 3 } }

      it "rounds churn rates to 2 decimal places" do
        result = service.build

        # (1 churned / 6 total) * 100 = 16.666...% -> 16.67%
        day1 = result[:data][:daily]["2020-01-15"]
        expect(day1[:by_product][product1.unique_permalink][:churn_rate]).to eq(16.67)
      end
    end
  end
end
