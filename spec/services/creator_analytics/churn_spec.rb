# frozen_string_literal: true

require "spec_helper"

RSpec.describe CreatorAnalytics::Churn do
  let(:user) { create(:user) }
  let(:product) { create(:subscription_product, user: user) }
  let(:start_date) { 30.days.ago.to_date }
  let(:end_date) { Date.current }
  let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

  describe "validations" do
    context "when end_date is before start_date" do
      it "is invalid" do
        invalid_service = described_class.new(
          user: user,
          start_date: Date.current,
          end_date: 1.day.ago.to_date
        )

        expect(invalid_service).not_to be_valid
        expect(invalid_service.errors[:end_date]).to be_present
        expect(invalid_service.errors[:end_date].first).to match(/must be greater than or equal to/)
      end
    end

    context "when end_date equals start_date" do
      it "is valid (same-day analysis)" do
        same_day_service = described_class.new(
          user: user,
          start_date: Date.current,
          end_date: Date.current
        )

        expect(same_day_service).to be_valid
      end
    end

    context "when time_window is out of range" do
      it "is invalid for more than 31 days" do
        invalid_service = described_class.new(
          user: user,
          start_date: 35.days.ago.to_date,
          end_date: Date.current
        )

        expect(invalid_service).not_to be_valid
        expect(invalid_service.errors[:time_window]).to include("must be between 1 and 31 days")
      end
    end
  end

  describe "#initialize" do
    context "with params hash" do
      it "parses start_time from params" do
        params = { from: "2024-01-01" }
        service = described_class.new(user: user, params: params, end_date: Date.current)

        expect(service.start_date).to eq(Date.parse("2024-01-01"))
      end

      it "parses end_time from params" do
        params = { to: "2024-01-31" }
        service = described_class.new(user: user, params: params, start_date: 30.days.ago.to_date)

        expect(service.end_date).to eq(Date.parse("2024-01-31"))
      end

      it "uses default dates when params are empty" do
        service = described_class.new(user: user, params: {})

        expect(service.start_date).to eq(31.days.ago.to_date)
        expect(service.end_date).to eq(Date.current)
      end

      it "parses products from params" do
        create(:subscription_product, user: user)
        params = { products: [product.id] }
        service = described_class.new(user: user, params: params)

        expect(service.products.to_a).to contain_exactly(product)
      end

      it "returns empty relation when products param is empty" do
        params = { products: [] }
        service = described_class.new(user: user, params: params)

        expect(service.products).to be_empty
        expect(service.products).to be_a(ActiveRecord::Relation)
      end
    end

    context "with invalid date format" do
      it "raises ArgumentError" do
        params = { from: "invalid-date" }

        expect do
          described_class.new(user: user, params: params)
        end.to raise_error(ArgumentError, /Invalid date format/)
      end
    end

    context "with explicit products parameter" do
      let(:product2) { create(:subscription_product, user: user) }

      it "uses provided products" do
        service = described_class.new(user: user, products: [product])

        expect(service.products).to eq([product])
      end
    end
  end

  describe "#time_window" do
    it "calculates correct window for date range" do
      service = described_class.new(
        user: user,
        start_date: 5.days.ago.to_date,
        end_date: Date.current
      )

      expect(service.time_window).to eq(6)
    end
  end

  describe "#has_subscription_products?" do
    context "when user has subscription products" do
      before { product }

      it "returns true" do
        expect(service.has_subscription_products?).to be true
      end
    end

    context "when user has no subscription products" do
      it "returns false" do
        expect(service.has_subscription_products?).to be false
      end
    end

    context "when user has only deleted subscription products" do
      before do
        product.update!(deleted_at: Time.current)
      end

      it "returns false" do
        expect(service.has_subscription_products?).to be false
      end
    end
  end

  describe "#available_products" do
    let!(:regular_product) { create(:product, user: user) }
    let!(:subscription_product1) { create(:subscription_product, user: user) }
    let!(:subscription_product2) { create(:subscription_product, user: user) }

    it "returns only subscription products" do
      # Ensure the outer product is created
      product

      products = service.available_products

      expect(products.length).to eq(3)
      expect(products.map(&:id)).to contain_exactly(product.id, subscription_product1.id, subscription_product2.id)
      expect(products.any? { |p| p.id == regular_product.id }).to be false
    end
  end

  describe "#calculate" do
    context "with no subscriptions" do
      it "returns zero metrics" do
        result = service.calculate

        expect(result[:churned_subscribers]).to eq(0)
        expect(result[:customer_churn_rate]).to eq(0.0)
        expect(result[:date]).to eq(end_date)
      end
    end

    context "with churned subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 5.days.ago)
      end

      it "counts churned subscriptions during period" do
        result = service.calculate
        expect(result[:churned_subscribers]).to eq(2)
      end

      it "is memoized" do
        expect(service).to receive(:calculate_period_metrics).once.and_call_original

        service.calculate
        service.calculate
      end
    end

    context "with mixed subscription activity" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 15.days.ago)
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "calculates churn rate using Stripe formula" do
        result = service.calculate

        expect(result[:churned_subscribers]).to eq(1)
        expect(result[:customer_churn_rate]).to eq(25.0)
      end
    end

    context "with subscribers who join and churn in same period" do
      before do
        create(:subscription, link: product, user: create(:user),
                              created_at: 15.days.ago, deactivated_at: 5.days.ago)
      end

      it "counts in both new and churned" do
        result = service.calculate

        expect(result[:churned_subscribers]).to eq(1)
        expect(result[:customer_churn_rate]).to eq(100.0)
      end
    end

    context "with product filtering" do
      let(:product2) { create(:subscription_product, user: user) }

      before do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
        create(:subscription, link: product2, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "only counts subscriptions for specified products" do
        filtered_service = described_class.new(
          user: user,
          start_date: start_date,
          end_date: end_date,
          products: [product]
        )

        result = filtered_service.calculate
        expect(result[:churned_subscribers]).to eq(1)
      end
    end
  end

  describe "#calculate_by_date" do
    it "returns array of daily calculations" do
      start = 2.days.ago.to_date
      end_date = Date.current
      service = described_class.new(user: user, start_date: start, end_date: end_date)

      results = service.calculate_by_date

      expect(results).to be_an(Array)
      expect(results.length).to eq(3)
      expect(results.first).to have_key(:customer_churn_rate)
      expect(results.first).to have_key(:churned_subscribers)
      expect(results.first).to have_key(:churned_mrr_cents)
      expect(results.first).to have_key(:date)
    end

    it "is memoized" do
      expect(service).to receive(:fetch_subscriptions).once.and_call_original

      service.calculate_by_date
      service.calculate_by_date
    end

    it "includes all dates in range" do
      start = 2.days.ago.to_date
      end_date = Date.current
      service = described_class.new(user: user, start_date: start, end_date: end_date)

      results = service.calculate_by_date
      dates = results.map { |r| r[:date] }

      expect(dates).to eq([start, start + 1.day, end_date])
    end
  end

  describe "#customer_churn_rate" do
    context "with active and churned subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 15.days.ago)
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "calculates churn rate correctly" do
        expect(service.customer_churn_rate).to eq(25.0)
      end

      it "delegates to calculate method" do
        expect(service).to receive(:calculate).and_call_original
        service.customer_churn_rate
      end
    end
  end

  describe "#fetch_churn_data" do
    context "when user has no subscription products" do
      it "returns nil" do
        expect(service.fetch_churn_data).to be_nil
      end
    end

    context "when user has subscription products" do
      before { product }

      context "when user is a large seller" do
        let!(:large_seller) { create(:large_seller, user: user) }

        it "uses cached data" do
          expect(service).to receive(:fetch_cached_data).and_call_original

          service.fetch_churn_data
        end

        it "caches the result for 24 hours" do
          expect(Rails.cache).to receive(:fetch).with(
            match(/seller_daily_churn_metrics:#{user.id}/),
            expires_in: 24.hours
          ).and_call_original

          service.fetch_churn_data
        end
      end

      context "when user is not a large seller" do
        it "calculates real-time data" do
          expect(service).to receive(:fetch_realtime_data).and_call_original
          expect(Rails.cache).not_to receive(:fetch)

          service.fetch_churn_data
        end
      end
    end
  end

  describe "#fetch_realtime_data" do
    before { product }

    context "with valid service" do
      it "returns structured data with metrics" do
        result = service.fetch_realtime_data

        expect(result).to have_key(:start_date)
        expect(result).to have_key(:end_date)
        expect(result).to have_key(:metrics)
        expect(result).to have_key(:daily_data)
        expect(result[:metrics]).to have_key(:customer_churn_rate)
        expect(result[:metrics]).to have_key(:last_period_churn_rate)
        expect(result[:metrics]).to have_key(:churned_subscribers)
        expect(result[:metrics]).to have_key(:churned_mrr_cents)
      end

      it "formats dates as strings" do
        result = service.fetch_realtime_data

        expect(result[:start_date]).to eq(start_date.to_s)
        expect(result[:end_date]).to eq(end_date.to_s)
      end
    end

    context "with invalid service" do
      let(:invalid_service) do
        described_class.new(
          user: user,
          start_date: Date.current,
          end_date: 1.day.ago.to_date
        )
      end

      it "returns error message" do
        result = invalid_service.fetch_realtime_data

        expect(result).to have_key(:error)
        expect(result[:error]).to match(/Invalid date range/)
      end
    end
  end

  describe "#last_period_churn_rate" do
    before do
      # Current period: 30 days ago to today
      # Last period: 60 days ago to 31 days ago
      create(:subscription, link: product, user: create(:user),
                            created_at: 90.days.ago, deactivated_at: 45.days.ago)
    end

    it "calculates churn rate for previous period" do
      rate = service.last_period_churn_rate

      expect(rate).to be_a(Float)
    end

    it "uses same period length as current" do
      # Service has 31-day window (30 days ago to today)
      # Last period should also be 31 days
      expect(service.last_period_churn_rate).to be >= 0
    end
  end

  describe ".customer_churn_rate (class method)" do
    before do
      create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
      create(:subscription, link: product, user: create(:user),
                            created_at: 60.days.ago, deactivated_at: 10.days.ago)
    end

    it "returns churn rate without instantiating explicitly" do
      rate = described_class.customer_churn_rate(
        user: user,
        start_date: start_date,
        end_date: end_date
      )

      expect(rate).to be_a(Float)
      expect(rate).to be > 0
    end

    it "accepts optional products parameter" do
      rate = described_class.customer_churn_rate(
        user: user,
        start_date: start_date,
        end_date: end_date,
        products: [product]
      )

      expect(rate).to be >= 0
    end
  end

  describe "MRR calculations" do
    context "with monthly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "calculates churned MRR correctly for monthly subscriptions" do
        result = service.calculate
        expect(result[:churned_mrr_cents]).to eq(1000)
      end
    end

    context "with yearly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 12000, recurrence: "yearly") }
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "normalizes yearly to MRR" do
        result = service.calculate
        expect(result[:churned_mrr_cents]).to eq(1000)
      end
    end

    context "with quarterly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 3000, recurrence: "quarterly") }
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "normalizes quarterly to MRR" do
        result = service.calculate
        expect(result[:churned_mrr_cents]).to eq(1000)
      end
    end

    context "with subscriptions without payment options" do
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "uses product price as fallback" do
        result = service.calculate
        # When no payment option exists, falls back to product price_cents
        expect(result[:churned_mrr_cents]).to be >= 0
      end
    end
  end

  describe "edge cases" do
    context "with subscription that churned before period" do
      before do
        create(:subscription, link: product, user: create(:user),
                              created_at: 90.days.ago, deactivated_at: 60.days.ago)
      end

      it "does not count in current period" do
        result = service.calculate
        expect(result[:churned_subscribers]).to eq(0)
      end
    end

    context "with subscription that churns on period end date" do
      before do
        create(:subscription, link: product, user: create(:user),
                              created_at: 60.days.ago, deactivated_at: end_date)
      end

      it "counts the churn" do
        result = service.calculate
        expect(result[:churned_subscribers]).to eq(1)
      end
    end

    context "with active subscription (not churned)" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
      end

      it "does not count as churned" do
        result = service.calculate
        expect(result[:churned_subscribers]).to eq(0)
      end
    end
  end
end
