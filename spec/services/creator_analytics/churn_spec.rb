# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  let(:user) { create(:user) }
  let(:start_date) { Date.new(2025, 9, 1) }
  let(:end_date) { Date.new(2025, 9, 30) }
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

    it "uses default dates when not provided" do
      service = described_class.new(user: user)

      expect(service.start_date).to eq(31.days.ago.to_date)
      expect(service.end_date).to eq(Date.current)
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

  describe "#calculate" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    before do
      @active_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 60.days.ago)
      @active_payment = create(:payment_option, subscription: @active_sub, price: monthly_price)
      @active_sub.update!(last_payment_option: @active_payment)

      @new_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 15.days.ago)
      @new_payment = create(:payment_option, subscription: @new_sub, price: monthly_price)
      @new_sub.update!(last_payment_option: @new_payment)

      @churned_sub = create(:subscription, link: subscription_product, user: create(:user),
                                           created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 15))
      @churned_payment = create(:payment_option, subscription: @churned_sub, price: monthly_price)
      @churned_sub.update!(last_payment_option: @churned_payment)
    end

    it "calculates metrics for the actual selected period" do
      result = service.calculate

      expect(result[:date]).to eq(end_date)
      expect(result[:customer_churn_rate]).to be_a(Numeric)
      expect(result[:churned_subscribers]).to be_a(Integer)
      expect(result[:churned_mrr_cents]).to be_a(Integer)
    end

    it "calculates correct churn rate for selected period" do
      result = service.calculate

      total_base = 2  # 1 active + 1 new
      churned_count = 1
      expected_churn_rate = (churned_count.to_f / total_base * 100).round(2)

      expect(result[:customer_churn_rate]).to eq(expected_churn_rate)
      expect(result[:churned_subscribers]).to eq(churned_count)
      expect(result[:churned_mrr_cents]).to eq(monthly_price.price_cents)
    end

    it "uses the correct date range for main metrics" do
      allow(service).to receive(:fetch_subscriptions).and_return(Subscription.none)

      service.calculate

      expect(service).to have_received(:fetch_subscriptions).with(from: start_date, to: end_date)
    end

    it "handles zero churn correctly" do
      @churned_sub.destroy

      result = service.calculate

      expect(result[:customer_churn_rate]).to eq(0.0)
      expect(result[:churned_subscribers]).to eq(0)
      expect(result[:churned_mrr_cents]).to eq(0)
    end

    it "handles zero base subscribers correctly" do
      Subscription.destroy_all

      result = service.calculate

      expect(result[:customer_churn_rate]).to eq(0.0)
      expect(result[:churned_subscribers]).to eq(0)
      expect(result[:churned_mrr_cents]).to eq(0)
    end

    it "handles high churn rate scenarios" do
      @active_sub.destroy
      @new_sub.destroy

      result = service.calculate

      total_base = 1  # only the churned subscriber counts as base
      churned_count = 1
      expected_churn_rate = (churned_count.to_f / total_base * 100).round(2)

      expect(result[:customer_churn_rate]).to eq(expected_churn_rate)
      expect(result[:churned_subscribers]).to eq(churned_count)
      expect(result[:churned_mrr_cents]).to eq(monthly_price.price_cents)
    end

    it "calculates churn rate with multiple churned subscribers" do
      additional_churned = create(:subscription, link: subscription_product, user: create(:user),
                                                 created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 20))
      additional_payment = create(:payment_option, subscription: additional_churned, price: monthly_price)
      additional_churned.update!(last_payment_option: additional_payment)

      result = service.calculate

      total_base = 3  # 1 active + 1 new + 1 additional churned
      churned_count = 2  # original + additional
      expected_churn_rate = (churned_count.to_f / total_base * 100).round(2)
      expected_mrr = churned_count * monthly_price.price_cents

      expect(result[:customer_churn_rate]).to eq(expected_churn_rate)
      expect(result[:churned_subscribers]).to eq(churned_count)
      expect(result[:churned_mrr_cents]).to eq(expected_mrr)
    end
  end

  describe "#calculate_by_date" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    before do
      @sub1 = create(:subscription, link: subscription_product, user: create(:user), created_at: 60.days.ago)
      @payment1 = create(:payment_option, subscription: @sub1, price: monthly_price)
      @sub1.update!(last_payment_option: @payment1)

      @sub2 = create(:subscription, link: subscription_product, user: create(:user), created_at: 15.days.ago)
      @payment2 = create(:payment_option, subscription: @sub2, price: monthly_price)
      @sub2.update!(last_payment_option: @payment2)
    end

    it "calculates daily metrics with 30-day rolling windows" do
      daily_results = service.calculate_by_date

      expect(daily_results).to be_an(Array)
      expect(daily_results.length).to eq(30)

      daily_results.each do |result|
        expect(result[:date]).to be_a(Date)
        expect(result[:customer_churn_rate]).to be_a(Numeric)
        expect(result[:churned_subscribers]).to be_a(Integer)
        expect(result[:churned_mrr_cents]).to be_a(Integer)
      end
    end

    it "uses 30-day rolling windows for each day" do
      daily_results = service.calculate_by_date

      daily_results.each_with_index do |result, index|
        expected_date = start_date + index.days
        expect(result[:date]).to eq(expected_date)
      end
    end

    it "uses different date ranges than main calculate method" do
      allow(service).to receive(:fetch_subscriptions).and_return(Subscription.none)

      service.calculate
      service.calculate_by_date

      expect(service).to have_received(:fetch_subscriptions).with(from: start_date, to: end_date)

      expect(service).to have_received(:fetch_subscriptions).with(from: start_date - 29.days, to: end_date)
    end

    it "calculates varying churn rates across different days" do
      churned_sub = create(:subscription, link: subscription_product, user: create(:user),
                                          created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 15))
      churned_payment = create(:payment_option, subscription: churned_sub, price: monthly_price)
      churned_sub.update!(last_payment_option: churned_payment)

      daily_results = service.calculate_by_date

      early_day_result = daily_results.find { |r| r[:date] == Date.new(2025, 9, 10) }
      later_day_result = daily_results.find { |r| r[:date] == Date.new(2025, 9, 20) }

      expect(early_day_result[:customer_churn_rate]).to eq(0.0)
      expect(later_day_result[:customer_churn_rate]).to be > 0
    end
  end

  describe "#calculate_period_metrics" do
    let(:service) { described_class.new(user: user) }

    before do
      @active_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 60.days.ago)
      @new_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 15.days.ago)
      @churned_sub = create(:subscription, link: subscription_product, user: create(:user),
                                           created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 15))

      [@active_sub, @new_sub, @churned_sub].each do |sub|
        payment = create(:payment_option, subscription: sub, price: monthly_price)
        sub.update!(last_payment_option: payment)
      end
    end

    it "calculates metrics for a specific period" do
      period_start = Date.new(2025, 9, 1)
      period_end = Date.new(2025, 9, 30)
      subscriptions = Subscription.all

      metrics = service.send(:calculate_period_metrics, period_start, period_end, subscriptions)

      expect(metrics[:churn_rate]).to be_a(Numeric)
      expect(metrics[:churned_count]).to be_a(Integer)
      expect(metrics[:churned_mrr]).to be_a(Integer)
    end

    it "correctly identifies active at period start" do
      period_start = Date.new(2025, 9, 1)
      period_end = Date.new(2025, 9, 30)
      subscriptions = Subscription.all

      metrics = service.send(:calculate_period_metrics, period_start, period_end, subscriptions)

      expect(metrics[:churn_rate]).to be > 0
    end

    it "handles edge case with subscription created exactly at period start" do
      edge_sub = create(:subscription, link: subscription_product, user: create(:user),
                                       created_at: Date.new(2025, 9, 1).beginning_of_day)
      edge_payment = create(:payment_option, subscription: edge_sub, price: monthly_price)
      edge_sub.update!(last_payment_option: edge_payment)

      period_start = Date.new(2025, 9, 1)
      period_end = Date.new(2025, 9, 30)
      subscriptions = Subscription.all

      metrics = service.send(:calculate_period_metrics, period_start, period_end, subscriptions)

      expect(metrics[:churn_rate]).to be_a(Numeric)
    end

    it "handles edge case with subscription deactivated exactly at period end" do
      edge_sub = create(:subscription, link: subscription_product, user: create(:user),
                                       created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 30).end_of_day)
      edge_payment = create(:payment_option, subscription: edge_sub, price: monthly_price)
      edge_sub.update!(last_payment_option: edge_payment)

      period_start = Date.new(2025, 9, 1)
      period_end = Date.new(2025, 9, 30)
      subscriptions = Subscription.all

      metrics = service.send(:calculate_period_metrics, period_start, period_end, subscriptions)

      expect(metrics[:churned_count]).to be > 0
    end
  end

  describe "#fetch_churn_data" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    before do
      create(:subscription_product, user: user)
    end

    it "returns nil when user has no subscription products" do
      service_without_products = described_class.new(user: create(:user))
      expect(service_without_products.fetch_churn_data).to be_nil
    end

    it "returns real-time data for regular users" do
      allow(service).to receive(:should_use_cache?).and_return(false)

      result = service.fetch_churn_data

      expect(result).to be_a(Hash)
      expect(result[:start_date]).to eq(start_date.to_s)
      expect(result[:end_date]).to eq(end_date.to_s)
      expect(result[:metrics]).to be_a(Hash)
      expect(result[:daily_data]).to be_an(Array)
    end

    it "returns cached data for large sellers" do
      create(:large_seller, user: user)
      allow(service).to receive(:should_use_cache?).and_return(true)

      result = service.fetch_churn_data

      expect(result).to be_a(Hash)
      expect(result[:start_date]).to eq(start_date.to_s)
      expect(result[:end_date]).to eq(end_date.to_s)
    end
  end

  describe "#last_period_churn_rate" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    before do
      create(:subscription_product, user: user)
    end

    it "calculates churn rate for the previous period of same length" do
      previous_start = start_date - 30.days
      start_date - 1.day

      sub = create(:subscription, link: subscription_product, user: create(:user), created_at: previous_start - 10.days)
      payment = create(:payment_option, subscription: sub, price: monthly_price)
      sub.update!(last_payment_option: payment)

      rate = service.last_period_churn_rate

      expect(rate).to be_a(Numeric)
      expect(rate).to be >= 0
    end

    it "handles case with no previous period data" do
      Subscription.destroy_all

      rate = service.last_period_churn_rate

      expect(rate).to eq(0.0)
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

    it "validates time window is between 1 and 31 days" do
      service = described_class.new(
        user: user,
        start_date: start_date,
        end_date: start_date + 35.days
      )

      expect(service.valid?).to be false
      expect(service.errors[:time_window]).to include("must be between 1 and 31 days")
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
  end

  describe "Main metrics vs Daily metrics difference" do
    let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

    before do
      @active_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 60.days.ago)
      @active_payment = create(:payment_option, subscription: @active_sub, price: monthly_price)
      @active_sub.update!(last_payment_option: @active_payment)

      @new_sub = create(:subscription, link: subscription_product, user: create(:user), created_at: 15.days.ago)
      @new_payment = create(:payment_option, subscription: @new_sub, price: monthly_price)
      @new_sub.update!(last_payment_option: @new_payment)

      @churned_sub = create(:subscription, link: subscription_product, user: create(:user),
                                           created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 15))
      @churned_payment = create(:payment_option, subscription: @churned_sub, price: monthly_price)
      @churned_sub.update!(last_payment_option: @churned_payment)
    end

    it "shows different metrics for main calculation vs daily calculations" do
      main_result = service.calculate
      daily_results = service.calculate_by_date

      expect(main_result[:date]).to eq(end_date)
      expect(main_result[:customer_churn_rate]).to eq(50.0)

      early_day_result = daily_results.find { |r| r[:date] == Date.new(2025, 9, 10) }
      expect(early_day_result[:customer_churn_rate]).to eq(0.0)

      later_day_result = daily_results.find { |r| r[:date] == Date.new(2025, 9, 20) }
      expect(later_day_result[:customer_churn_rate]).to be > 0
    end

    it "verifies main metrics use selected period, daily metrics use 30-day rolling" do
      allow(service).to receive(:fetch_subscriptions).and_return(Subscription.none)

      service.calculate
      service.calculate_by_date

      expect(service).to have_received(:fetch_subscriptions).with(from: start_date, to: end_date)
      expect(service).to have_received(:fetch_subscriptions).with(from: start_date - 29.days, to: end_date)
    end
  end

  describe "MRR calculation" do
    let(:service) { described_class.new(user: user) }

    it "correctly calculates monthly MRR for monthly subscriptions" do
      sub = create(:subscription, link: subscription_product, user: create(:user))
      monthly_price = create(:price, link: subscription_product, price_cents: 1000, recurrence: "monthly")
      payment = create(:payment_option, subscription: sub, price: monthly_price)
      sub.update!(last_payment_option: payment)

      mrr = service.send(:calculate_mrr_cents, sub)
      expected_mrr = monthly_price.price_cents
      expect(mrr).to eq(expected_mrr)
    end

    it "correctly calculates monthly MRR for yearly subscriptions" do
      sub = create(:subscription, link: subscription_product, user: create(:user))
      yearly_price = create(:price, link: subscription_product, price_cents: 12000, recurrence: "yearly")
      payment = create(:payment_option, subscription: sub, price: yearly_price)
      sub.update!(last_payment_option: payment)

      mrr = service.send(:calculate_mrr_cents, sub)
      expected_mrr = (yearly_price.price_cents / 12.0).round
      expect(mrr).to eq(expected_mrr)
    end

    it "correctly calculates monthly MRR for quarterly subscriptions" do
      sub = create(:subscription, link: subscription_product, user: create(:user))
      quarterly_price = create(:price, link: subscription_product, price_cents: 3000, recurrence: "quarterly")
      payment = create(:payment_option, subscription: sub, price: quarterly_price)
      sub.update!(last_payment_option: payment)

      mrr = service.send(:calculate_mrr_cents, sub)
      expected_mrr = (quarterly_price.price_cents / 3.0).round
      expect(mrr).to eq(expected_mrr)
    end

    it "returns 0 for subscriptions without payment options" do
      sub = create(:subscription, link: subscription_product, user: create(:user))

      allow(sub).to receive(:last_payment_option).and_return(nil)

      mrr = service.send(:calculate_mrr_cents, sub)
      expect(mrr).to eq(0)
    end

    it "handles unsupported recurrence types" do
      sub = create(:subscription, link: subscription_product, user: create(:user))
      monthly_price = create(:price, link: subscription_product, price_cents: 1000, recurrence: "monthly")
      payment = create(:payment_option, subscription: sub, price: monthly_price)
      sub.update!(last_payment_option: payment)

      allow(payment.price).to receive(:recurrence).and_return("weekly")

      mrr = service.send(:calculate_mrr_cents, sub)
      expect(mrr).to eq(0)
    end
  end

  describe "Edge cases and error handling" do
    it "handles subscriptions with nil deactivated_at" do
      service = described_class.new(user: user, start_date: start_date, end_date: end_date)

      active_sub = create(:subscription, link: subscription_product, user: create(:user),
                                         created_at: 60.days.ago, deactivated_at: nil)
      payment = create(:payment_option, subscription: active_sub, price: monthly_price)
      active_sub.update!(last_payment_option: payment)

      result = service.calculate
      expect(result[:churned_subscribers]).to eq(0)
    end

    it "handles subscriptions with nil last_payment_option" do
      service = described_class.new(user: user)

      sub = create(:subscription, link: subscription_product, user: create(:user),
                                  created_at: 60.days.ago, deactivated_at: Date.new(2025, 9, 15))

      allow(sub).to receive(:last_payment_option).and_return(nil)

      mrr = service.send(:calculate_mrr_cents, sub)
      expect(mrr).to eq(0)
    end

    it "handles zero price subscriptions" do
      service = described_class.new(user: user)

      sub = create(:subscription, link: subscription_product, user: create(:user))
      zero_price = create(:price, link: subscription_product, price_cents: 0, recurrence: "monthly")
      payment = create(:payment_option, subscription: sub, price: zero_price)
      sub.update!(last_payment_option: payment)

      mrr = service.send(:calculate_mrr_cents, sub)
      expect(mrr).to eq(0)
    end

    it "handles invalid date parameters gracefully" do
      expect do
        described_class.new(user: user, params: { from: "invalid-date", to: "2025-09-30" })
      end.to raise_error(ArgumentError)
    end

    it "handles missing date parameters" do
      service = described_class.new(user: user, params: {})

      expect(service.start_date).to eq(31.days.ago.to_date)
      expect(service.end_date).to eq(Date.current)
    end
  end
end
