# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  let(:user_timezone) { "UTC" }

  before do
    @user = create(:user, timezone: user_timezone)
    @product = create(:subscription_product, user: @user, subscription_duration: "monthly")
    @service = described_class.new(
      user: @user,
      products: [@product],
      dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
    )

    # Create subscriptions for testing churn
    # Active subscriptions at start (created before period)
    @active_sub_1 = create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 15), price: 1000)
    @active_sub_2 = create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 20), price: 1000)

    # New subscription during period (Jan 1)
    @new_sub = create(:subscription, link: @product, seller: @user, created_at: Time.utc(2021, 1, 1, 10), price: 1000)

    # Cancelled subscription during period (Jan 2)
    @cancelled_sub = create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 10), price: 1500, cancelled_at: Time.utc(2021, 1, 2, 12))

    # Failed subscription during period (Jan 3)
    @failed_sub = create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 5), price: 2000, failed_at: Time.utc(2021, 1, 3, 14))

    # Subscription outside of period (should not be counted)
    create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 1), price: 1000, cancelled_at: Time.utc(2021, 1, 4))

    # Test subscription (should be excluded)
    create(:subscription, link: @product, seller: @user, created_at: Time.utc(2020, 12, 1), price: 1000, is_test_subscription: true)
  end

  describe "#by_product_and_date" do
    it "returns churn data grouped by product and date" do
      result = @service.by_product_and_date

      # Jan 1: 2 active at start + 1 new = 3 total, 0 cancelled, churn rate = 0%
      jan_1_key = [@product.id, "2021-01-01"]
      expect(result[jan_1_key]).to include(
        churn_rate: 0.0,
        cancelled_count: 0,
        active_at_start: 2,
        new_subscriptions: 1
      )

      # Jan 2: 3 active at start + 0 new = 3 total, 1 cancelled, churn rate = 33.33%
      jan_2_key = [@product.id, "2021-01-02"]
      expect(result[jan_2_key]).to include(
        churn_rate: 33.33,
        cancelled_count: 1,
        revenue_lost_cents: 1500,
        active_at_start: 3,
        new_subscriptions: 0
      )

      # Jan 3: 3 active at start + 0 new = 3 total, 1 failed, churn rate = 33.33%
      jan_3_key = [@product.id, "2021-01-03"]
      expect(result[jan_3_key]).to include(
        churn_rate: 33.33,
        cancelled_count: 1,
        revenue_lost_cents: 2000,
        active_at_start: 3,
        new_subscriptions: 0
      )
    end

    it "returns empty hash when products array is empty" do
      service = described_class.new(
        user: @user,
        products: [],
        dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
      )

      expect(service.by_product_and_date).to eq({})
    end

    it "handles period with no subscriptions" do
      service = described_class.new(
        user: @user,
        products: [@product],
        dates: (Date.new(2020, 1, 1) .. Date.new(2020, 1, 3)).to_a
      )

      result = service.by_product_and_date
      jan_1_key = [@product.id, "2020-01-01"]

      expect(result[jan_1_key]).to include(
        churn_rate: 0.0,
        cancelled_count: 0,
        revenue_lost_cents: 0,
        active_at_start: 0,
        new_subscriptions: 0
      )
    end

    it "excludes test subscriptions" do
      # All our subscriptions are for @user, the test subscription should be excluded
      result = @service.by_product_and_date

      # Verify counts don't include test subscription
      jan_1_key = [@product.id, "2021-01-01"]
      expect(result[jan_1_key][:active_at_start]).to eq(2) # Not 3
    end
  end

  describe "#summary" do
    it "returns aggregated churn data for current and last period" do
      summary = @service.summary

      expect(summary).to include(
        has_subscription_products: true,
        start_date: "2021-01-01",
        end_date: "2021-01-03"
      )

      # Current period: 2 active at start + 1 new = 3, 2 cancelled (Jan 2 & 3)
      # Churn rate = (2 / 3) × 100 = 66.67%
      expect(summary[:current_period]).to include(
        churn_rate: 66.67,
        churned_users: 2,
        revenue_lost_cents: 3500, # 1500 + 2000
        active_at_start: 2,
        new_subscriptions: 1
      )

      # Last period should have metrics too
      expect(summary[:last_period]).to be_a(Hash)
      expect(summary[:last_period]).to include(
        :churn_rate,
        :churned_users,
        :revenue_lost_cents
      )
    end

    it "returns default summary when products array is empty" do
      service = described_class.new(
        user: @user,
        products: [],
        dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
      )

      summary = service.summary

      expect(summary).to include(
        has_subscription_products: false,
        start_date: "2021-01-01",
        end_date: "2021-01-03"
      )

      expect(summary[:current_period]).to include(
        churn_rate: 0.0,
        churned_users: 0,
        revenue_lost_cents: 0,
        active_at_start: 0,
        new_subscriptions: 0
      )
    end

    it "calculates last period metrics correctly" do
      # Create subscriptions in the last period (Dec 29-31, 2020)
      last_period_product = create(:subscription_product, user: @user)

      # Active before last period
      create(:subscription, link: last_period_product, seller: @user, created_at: Time.utc(2020, 12, 1))

      # Cancelled in last period
      create(:subscription, link: last_period_product, seller: @user, created_at: Time.utc(2020, 12, 1), price: 1000, cancelled_at: Time.utc(2020, 12, 30))

      service = described_class.new(
        user: @user,
        products: [last_period_product],
        dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
      )

      summary = service.summary

      # Last period should show the cancellation
      expect(summary[:last_period][:churned_users]).to be >= 1
    end
  end

  describe "churn calculation formula" do
    it "follows the specified formula: (Cancelled / (Active at start + New)) × 100" do
      # Setup: 10 active, 3 new, 2 cancelled
      # Expected: (2 / 13) × 100 = 15.38%

      product = create(:subscription_product, user: @user)
      date_range = (Date.new(2021, 2, 1) .. Date.new(2021, 2, 1)).to_a

      # 10 active at start
      10.times do |i|
        create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 1, 15, i))
      end

      # 3 new during period
      3.times do |i|
        create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 2, 1, i))
      end

      # 2 cancelled during period
      2.times do |i|
        create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 1, 10, i), cancelled_at: Time.utc(2021, 2, 1, 10 + i))
      end

      service = described_class.new(user: @user, products: [product], dates: date_range)
      result = service.by_product_and_date

      key = [product.id, "2021-02-01"]
      expect(result[key][:churn_rate]).to eq(15.38)
      expect(result[key][:active_at_start]).to eq(10)
      expect(result[key][:new_subscriptions]).to eq(3)
      expect(result[key][:cancelled_count]).to eq(2)
    end
  end

  describe "edge cases" do
    it "returns 0% churn rate when denominator is 0" do
      product = create(:subscription_product, user: @user)
      date_range = (Date.new(2021, 2, 1) .. Date.new(2021, 2, 1)).to_a

      service = described_class.new(user: @user, products: [product], dates: date_range)
      result = service.by_product_and_date

      key = [product.id, "2021-02-01"]
      expect(result[key][:churn_rate]).to eq(0.0)
    end

    it "handles subscriptions with nil price" do
      product = create(:subscription_product, user: @user)
      date_range = (Date.new(2021, 2, 1) .. Date.new(2021, 2, 1)).to_a

      create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 1, 15), price: nil, cancelled_at: Time.utc(2021, 2, 1, 12))

      service = described_class.new(user: @user, products: [product], dates: date_range)
      result = service.by_product_and_date

      key = [product.id, "2021-02-01"]
      expect(result[key][:revenue_lost_cents]).to eq(0)
    end

    it "counts ended subscriptions as churned" do
      product = create(:subscription_product, user: @user)
      date_range = (Date.new(2021, 2, 1) .. Date.new(2021, 2, 1)).to_a

      create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 1, 15), ended_at: Time.utc(2021, 2, 1, 12))

      service = described_class.new(user: @user, products: [product], dates: date_range)
      result = service.by_product_and_date

      key = [product.id, "2021-02-01"]
      expect(result[key][:cancelled_count]).to eq(1)
    end

    it "counts deactivated subscriptions as churned" do
      product = create(:subscription_product, user: @user)
      date_range = (Date.new(2021, 2, 1) .. Date.new(2021, 2, 1)).to_a

      create(:subscription, link: product, seller: @user, created_at: Time.utc(2021, 1, 15), deactivated_at: Time.utc(2021, 2, 1, 12))

      service = described_class.new(user: @user, products: [product], dates: date_range)
      result = service.by_product_and_date

      key = [product.id, "2021-02-01"]
      expect(result[key][:cancelled_count]).to eq(1)
    end
  end
end
