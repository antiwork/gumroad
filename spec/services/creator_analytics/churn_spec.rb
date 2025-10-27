# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  include ChurnTestHelpers

  let(:user) { create(:user) }
  let(:start_date) { Date.new(2025, 9, 1) }
  let(:end_date) { Date.new(2025, 9, 30) }
  let(:mid_period_date) { start_date + 14.days }
  let(:subscription_product) { create(:subscription_product, user: user) }
  let(:monthly_price) { create(:price, link: subscription_product, price_cents: 1000, recurrence: "monthly") }

  describe "#initialize" do
    it "sets up the service with correct parameters" do
      service = described_class.new(
        user: user,
        start_date: start_date,
        end_date: end_date,
        params: { products: [subscription_product.id] }
      )

      expect(service.user).to eq(user)
      expect(service.start_date).to eq(start_date)
      expect(service.end_date).to eq(end_date)
    end

    it "parses dates from params when not provided directly" do
      service = described_class.new(
        user: user,
        params: { from: "2025-09-01", to: "2025-09-30" }
      )

      expect(service.start_date).to eq(Date.new(2025, 9, 1))
      expect(service.end_date).to eq(Date.new(2025, 9, 30))
    end

    it "prioritizes start_time param over from param" do
      service = described_class.new(
        user: user,
        params: { start_time: "2025-09-01", from: "2025-08-01" }
      )

      expect(service.start_date).to eq(Date.new(2025, 9, 1))
    end

    it "prioritizes end_time param over to param" do
      service = described_class.new(
        user: user,
        params: { end_time: "2025-09-30", to: "2025-10-30" }
      )

      expect(service.end_date).to eq(Date.new(2025, 9, 30))
    end

    it "uses default dates when not provided" do
      freeze_time = Time.zone.parse("2025-09-15 12:00:00")
      travel_to(freeze_time) do
        service = described_class.new(user: user)

        expect(service.start_date).to eq(Date.new(2025, 8, 15))
        expect(service.end_date).to eq(Date.new(2025, 9, 15))
      end
    end
  end

  describe "#time_window" do
    it "calculates the correct time window" do
      service = described_class.new(
        user: user,
        start_date: start_date,
        end_date: end_date
      )

      expect(service.time_window).to eq(30)
    end
  end

  describe "#has_subscription_products?" do
    it "returns true when user has subscription products" do
      create(:subscription_product, user: user)
      service = described_class.new(user: user)

      expect(service.has_subscription_products?).to be true
    end

    it "returns false when user has no subscription products" do
      service = described_class.new(user: user)

      expect(service.has_subscription_products?).to be false
    end
  end

  describe "#available_products" do
    it "returns subscription products for the user" do
      product1 = create(:subscription_product, user: user)
      product2 = create(:subscription_product, user: user)
      create(:product, user: user)

      service = described_class.new(user: user)

      expect(service.available_products).to contain_exactly(product1, product2)
    end
  end

  describe "#fetch_churn_data" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    context "when user has no subscription products" do
      it "returns nil" do
        service_without_products = described_class.new(user: create(:user))
        expect(service_without_products.fetch_churn_data).to be_nil
      end
    end

    context "when user has subscription products" do
      before do
        create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago)
        create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + 5.days)
        create_churned_subscription(product: subscription_product, price: monthly_price,
                                    created_at: 60.days.ago, deactivated_at: mid_period_date)
      end

      it "returns hash with correct structure" do
        result = service.fetch_churn_data

        expect(result).to be_a(Hash)
        expect(result).to have_key(:start_date)
        expect(result).to have_key(:end_date)
        expect(result).to have_key(:metrics)
        expect(result).to have_key(:daily_data)
      end

      it "returns correct date range" do
        result = service.fetch_churn_data

        expect(result[:start_date]).to eq(start_date.to_s)
        expect(result[:end_date]).to eq(end_date.to_s)
      end

      it "includes metrics hash with all required fields" do
        result = service.fetch_churn_data

        expect(result[:metrics]).to include(
          :customer_churn_rate,
          :last_period_churn_rate,
          :churned_subscribers,
          :churned_mrr_cents
        )
      end

      it "includes daily data array" do
        result = service.fetch_churn_data

        expect(result[:daily_data]).to be_an(Array)
        expect(result[:daily_data].length).to eq(30)

        result[:daily_data].each do |daily|
          expect(daily).to include(:date, :month, :month_index, :customer_churn_rate, :churned_subscribers, :churned_mrr_cents, :active_at_start, :new_subscribers)
        end
      end

      it "calculates churn rate correctly" do
        result = service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to be_a(Numeric)
        expect(result[:metrics][:customer_churn_rate]).to be >= 0
        expect(result[:metrics][:churned_subscribers]).to eq(1)
      end

      context "with caching for large sellers" do
        before { create(:large_seller, user: user) }

        it "returns cached data" do
          result = service.fetch_churn_data
          expect(result).to be_a(Hash)
        end
      end

      context "with product filtering" do
        it "filters churn data by selected products" do
          product1 = create(:subscription_product, user: user)
          product2 = create(:subscription_product, user: user)

          create_churned_subscription(product: product1, price: monthly_price,
                                      created_at: 60.days.ago, deactivated_at: mid_period_date)
          create_churned_subscription(product: product2, price: monthly_price,
                                      created_at: 60.days.ago, deactivated_at: mid_period_date)

          filtered_service = described_class.new(
            user: user,
            start_date: start_date,
            end_date: end_date,
            params: { products: [product1.id] }
          )
          result = filtered_service.fetch_churn_data

          expect(result[:metrics][:churned_subscribers]).to eq(1)
          expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
        end
      end
    end

    context "with invalid date range" do
      before { create(:subscription_product, user: user) }

      it "raises ArgumentError when end_date is before start_date" do
        invalid_service = described_class.new(
          user: user,
          start_date: end_date,
          end_date: start_date
        )

        expect { invalid_service.fetch_churn_data }.to raise_error(ArgumentError, /Invalid date range/)
      end
    end
  end

  describe "validation" do
    it "validates end_date is after start_date" do
      service = described_class.new(
        user: user,
        start_date: end_date,
        end_date: start_date
      )

      expect(service.valid?).to be false
      expect(service.errors[:end_date]).to include("must be greater than or equal to #{end_date}")
    end

    it "validates same day start and end date" do
      service = described_class.new(
        user: user,
        start_date: start_date,
        end_date: start_date
      )

      expect(service.valid?).to be true
      expect(service.time_window).to eq(1)
    end

    it "allows date ranges longer than 31 days" do
      service = described_class.new(
        user: user,
        start_date: start_date,
        end_date: start_date + 90.days
      )

      expect(service.valid?).to be true
      expect(service.time_window).to eq(91)
    end
  end

  describe "churn rate calculations" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    context "with standard churn scenario" do
      before do
        create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago)
        create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + 5.days)
        create_churned_subscription(product: subscription_product, price: monthly_price,
                                    created_at: 60.days.ago, deactivated_at: mid_period_date)
      end

      it "calculates correct churn metrics" do
        result = service.fetch_churn_data

        expect(result[:metrics][:churned_subscribers]).to eq(1)
        expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
        expect(result[:metrics][:customer_churn_rate]).to be > 0
      end
    end

    context "with no churn" do
      before do
        create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago)
        create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + 5.days)
      end

      it "returns zero churn rate" do
        result = service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to eq(0.0)
        expect(result[:metrics][:churned_subscribers]).to eq(0)
        expect(result[:metrics][:churned_mrr_cents]).to eq(0)
      end
    end

    context "with no subscribers" do
      before { create(:subscription_product, user: user) }

      it "returns zero metrics" do
        result = service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to eq(0.0)
        expect(result[:metrics][:churned_subscribers]).to eq(0)
        expect(result[:metrics][:churned_mrr_cents]).to eq(0)
      end
    end

    context "with 100% churn" do
      before do
        create_churned_subscription(product: subscription_product, price: monthly_price,
                                    created_at: start_date, deactivated_at: start_date + 5.days)
      end

      it "returns 100% churn rate" do
        result = service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to eq(100.0)
        expect(result[:metrics][:churned_subscribers]).to eq(1)
      end
    end

    context "with multiple churned subscribers" do
      before do
        create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago)
        create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + 5.days)
        create_churned_subscription(product: subscription_product, price: monthly_price,
                                    created_at: 60.days.ago, deactivated_at: start_date + 10.days)
        create_churned_subscription(product: subscription_product, price: monthly_price,
                                    created_at: 60.days.ago, deactivated_at: start_date + 15.days)
      end

      it "calculates total churn correctly" do
        result = service.fetch_churn_data

        expect(result[:metrics][:churned_subscribers]).to eq(2)
        expect(result[:metrics][:churned_mrr_cents]).to eq(2000)
      end
    end
  end

  describe "Stripe churn rate formula verification" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    context "monthly churn rate" do
      it "calculates using Stripe's formula: (churned / total_base) × 100" do
        10.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }
        3.times { |i| create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + i.days) }
        2.times { |i| create_churned_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: start_date + 10.days + i.days) }

        result = service.fetch_churn_data

        expected_churn_rate = (2.0 / 15.0 * 100).round(2)
        expect(result[:metrics][:customer_churn_rate]).to eq(expected_churn_rate)
        expect(result[:metrics][:churned_subscribers]).to eq(2)
      end

      it "handles edge case with only new subscribers" do
        5.times { |i| create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + i.days) }
        create_churned_subscription(product: subscription_product, price: monthly_price, created_at: start_date, deactivated_at: start_date + 5.days)

        result = service.fetch_churn_data

        expected_churn_rate = (1.0 / 6.0 * 100).round(2)
        expect(result[:metrics][:customer_churn_rate]).to eq(expected_churn_rate)
      end

      it "returns 0% when no customers churn" do
        5.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }

        result = service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to eq(0.0)
        expect(result[:metrics][:churned_subscribers]).to eq(0)
      end
    end

    context "daily churn rate" do
      it "calculates churn for each day independently" do
        10.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }

        churned_day_1 = start_date + 5.days
        churned_day_2 = start_date + 10.days

        create_churned_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: churned_day_1)
        create_churned_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: churned_day_2)

        result = service.fetch_churn_data

        day_1_metrics = result[:daily_data].find { |d| d[:date] == churned_day_1.to_s }
        day_2_metrics = result[:daily_data].find { |d| d[:date] == churned_day_2.to_s }
        no_churn_day_metrics = result[:daily_data].find { |d| d[:date] == (start_date + 15.days).to_s }

        expect(day_1_metrics[:customer_churn_rate]).to be > 0
        expect(day_2_metrics[:customer_churn_rate]).to be > 0
        expect(no_churn_day_metrics[:customer_churn_rate]).to eq(0.0)
      end

      it "includes new subscribers created on same day as churn" do
        5.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }

        churn_day = start_date + 5.days

        2.times { create_new_subscription(product: subscription_product, price: monthly_price, created_at: churn_day) }
        create_churned_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: churn_day)

        result = service.fetch_churn_data
        day_result = result[:daily_data].find { |d| d[:date] == churn_day.to_s }

        expected_churn_rate = (1.0 / 8.0 * 100).round(2)
        expect(day_result[:customer_churn_rate]).to eq(expected_churn_rate)
      end
    end
  end

  describe "MRR calculations" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    it "correctly calculates MRR for monthly subscriptions" do
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: 60.days.ago, deactivated_at: mid_period_date)

      result = service.fetch_churn_data

      expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
    end

    it "converts yearly subscription price to monthly MRR" do
      yearly_price = create(:price, link: subscription_product, price_cents: 12000, recurrence: "yearly")
      create_churned_subscription(product: subscription_product, price: yearly_price,
                                  created_at: 60.days.ago, deactivated_at: mid_period_date)

      result = service.fetch_churn_data

      expected_monthly_mrr = (12000 / 12.0).round
      expect(result[:metrics][:churned_mrr_cents]).to eq(expected_monthly_mrr)
    end

    it "converts quarterly subscription price to monthly MRR" do
      quarterly_price = create(:price, link: subscription_product, price_cents: 3000, recurrence: "quarterly")
      create_churned_subscription(product: subscription_product, price: quarterly_price,
                                  created_at: 60.days.ago, deactivated_at: mid_period_date)

      result = service.fetch_churn_data

      expected_monthly_mrr = (3000 / 3.0).round
      expect(result[:metrics][:churned_mrr_cents]).to eq(expected_monthly_mrr)
    end

    it "handles subscriptions with different MRR values" do
      high_mrr_price = create(:price, link: subscription_product, price_cents: 5000, recurrence: "monthly")
      low_mrr_price = create(:price, link: subscription_product, price_cents: 1000, recurrence: "monthly")

      create_active_subscription(product: subscription_product, price: high_mrr_price, created_at: 60.days.ago)
      create_active_subscription(product: subscription_product, price: low_mrr_price, created_at: 60.days.ago)
      create_new_subscription(product: subscription_product, price: low_mrr_price, created_at: start_date + 5.days)
      create_churned_subscription(product: subscription_product, price: high_mrr_price,
                                  created_at: 60.days.ago, deactivated_at: start_date + 10.days)

      result = service.fetch_churn_data

      expect(result[:metrics][:churned_mrr_cents]).to eq(5000)
    end
  end

  describe "last period comparison" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    it "calculates last period churn rate for same period length" do
      last_period_start = start_date - 30.days

      5.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: last_period_start - 10.days) }
      2.times { |i| create_new_subscription(product: subscription_product, price: monthly_price, created_at: last_period_start + i.days) }
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: last_period_start - 5.days, deactivated_at: last_period_start + 10.days)

      result = service.fetch_churn_data

      expect(result[:metrics][:last_period_churn_rate]).to be_a(Numeric)
      expect(result[:metrics][:last_period_churn_rate]).to be >= 0
    end

    it "handles different period lengths" do
      short_service = described_class.new(user: user, start_date: Date.new(2025, 9, 1), end_date: Date.new(2025, 9, 7))
      last_period_start = Date.new(2025, 9, 1) - 7.days

      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: last_period_start - 5.days, deactivated_at: last_period_start + 3.days)

      result = short_service.fetch_churn_data

      expect(result[:metrics][:last_period_churn_rate]).to be_a(Numeric)
    end

    context "when no data exists" do
      before { create(:subscription_product, user: user) }

      it "returns 0 for last period churn rate" do
        result = service.fetch_churn_data

        expect(result[:metrics][:last_period_churn_rate]).to eq(0.0)
      end
    end
  end

  describe "highlighted metrics verification" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    it "correctly calculates all highlighted metrics per requirements" do
      5.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }
      2.times { |i| create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date + i.days) }
      2.times { |i| create_churned_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: start_date + 10.days + i.days) }

      last_period_start = start_date - 30.days
      3.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: last_period_start - 10.days) }
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: last_period_start - 5.days, deactivated_at: last_period_start + 5.days)

      result = service.fetch_churn_data

      expect(result[:metrics][:customer_churn_rate]).to be_a(Numeric)
      expect(result[:metrics][:churned_subscribers]).to eq(2)
      expect(result[:metrics][:churned_mrr_cents]).to eq(2000)
      expect(result[:metrics][:last_period_churn_rate]).to be_a(Numeric)
    end
  end

  describe "edge cases" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    it "handles subscriptions with nil deactivated_at" do
      create_active_subscription(product: subscription_product, price: monthly_price,
                                 created_at: 60.days.ago, deactivated_at: nil)

      result = service.fetch_churn_data

      expect(result[:metrics][:churned_subscribers]).to eq(0)
    end

    it "handles subscriptions created at period boundary" do
      create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date.beginning_of_day)

      result = service.fetch_churn_data

      expect(result[:metrics]).to be_a(Hash)
    end

    it "handles subscriptions deactivated at period boundary" do
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: 60.days.ago, deactivated_at: end_date.end_of_day)

      result = service.fetch_churn_data

      expect(result[:metrics][:churned_subscribers]).to be > 0
    end

    it "handles invalid date parameters" do
      expect do
        described_class.new(user: user, params: { from: "invalid-date", to: "2025-09-30" })
      end.to raise_error(ArgumentError)
    end

    it "rounds churn rate to 2 decimal places" do
      7.times { create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago) }
      create_new_subscription(product: subscription_product, price: monthly_price, created_at: start_date)
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: 60.days.ago, deactivated_at: start_date + 5.days)

      result = service.fetch_churn_data

      expected_churn_rate = (1.0 / 9.0 * 100).round(2)
      expect(result[:metrics][:customer_churn_rate]).to eq(expected_churn_rate)
    end
  end

  describe ".customer_churn_rate class method" do
    it "calculates churn rate without full data structure" do
      create_active_subscription(product: subscription_product, price: monthly_price, created_at: 60.days.ago)
      create_churned_subscription(product: subscription_product, price: monthly_price,
                                  created_at: 60.days.ago, deactivated_at: mid_period_date)

      rate = described_class.customer_churn_rate(
        user: user,
        start_date: start_date,
        end_date: end_date
      )

      expect(rate).to be_a(Numeric)
      expect(rate).to be > 0
    end
  end
end
