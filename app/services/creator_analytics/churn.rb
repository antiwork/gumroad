# frozen_string_literal: true

class CreatorAnalytics::Churn
  include ActiveModel::Validations

  validates :end_date, comparison: { greater_than_or_equal_to: :start_date }
  validates :time_window, inclusion: { in: 1..31, message: "must be between 1 and 31 days" }

  attr_reader :start_date, :end_date, :user, :products

  def initialize(user:, start_date: nil, end_date: nil, params: {}, products: nil)
    @user = user
    @params = params
    @start_date = parse_date(start_date, :start)
    @end_date = parse_date(end_date, :end)
    @products = products || parse_products
  end

  def time_window
    (end_date - start_date).to_i + 1
  end

  def calculate
    @calculate ||= begin
      period_start = start_date - 29.days
      subscriptions = fetch_subscriptions(from: period_start, to: end_date).to_a
      metrics = calculate_period_metrics(period_start, end_date, subscriptions)

      {
        date: end_date,
        customer_churn_rate: metrics[:churn_rate],
        churned_subscribers: metrics[:churned_count],
        churned_mrr_cents: metrics[:churned_mrr]
      }
    end
  end

  def fetch_churn_data
    return nil unless has_subscription_products?

    if should_use_cache?
      fetch_cached_data
    else
      fetch_realtime_data
    end
  end

  def has_subscription_products?
    user.products.alive.is_recurring_billing.exists?
  end

  def available_products
    user.products_for_creator_analytics.select(&:is_recurring_billing?)
  end

  def calculate_by_date
    @calculate_by_date ||= begin
      earliest_date = start_date - 29.days
      all_subscriptions = fetch_subscriptions(from: earliest_date, to: end_date).to_a

      (start_date..end_date).map do |date|
        period_start = date - 29.days
        calculate_for_period(period_start, date, all_subscriptions)
      end
    end
  end

  def customer_churn_rate
    calculate[:customer_churn_rate]
  end

  def build_metrics(result)
    {
      customer_churn_rate: result[:customer_churn_rate].to_f,
      last_period_churn_rate: last_period_churn_rate.to_f,
      churned_subscribers: result[:churned_subscribers],
      churned_mrr_cents: result[:churned_mrr_cents]
    }
  end

  def fetch_realtime_data
    return { error: "Invalid date range: #{errors.full_messages.join(', ')}" } unless valid?

    result = calculate
    daily_results = calculate_by_date

    {
      start_date: start_date.to_s,
      end_date: end_date.to_s,
      metrics: build_metrics(result),
      daily_data: format_daily_data(daily_results)
    }
  end

  def last_period_churn_rate
    period_length = (end_date - start_date).to_i
    last_period_end = start_date - 1.day
    last_period_start = last_period_end - period_length.days

    self.class.customer_churn_rate(
      user: user,
      start_date: last_period_start,
      end_date: last_period_end,
      products: @products
    )
  end

  def self.customer_churn_rate(user:, start_date:, end_date:, products: nil)
    new(
      user: user,
      start_date: start_date,
      end_date: end_date,
      products: products
    ).customer_churn_rate
  end

  private
    def parse_date(date_value, type)
      return date_value.to_date if date_value

      case type
      when :start
        (@params[:start_time] || @params[:from])&.to_date || 31.days.ago.to_date
      when :end
        (@params[:end_time] || @params[:to])&.to_date || Date.current
      end
    rescue Date::Error => e
      raise ArgumentError, "Invalid date format: #{e.message}"
    end

    def parse_products
      return Link.none unless @params[:products].present?

      @user.products.where(id: @params[:products])
    end

    def should_use_cache?
      LargeSeller.where(user: user).exists?
    end

    def cache_key
      @cache_key ||= begin
        product_ids = if @products.respond_to?(:map)
          @products.map(&:id).sort.join(",")
        else
          "all"
        end
        "seller_daily_churn_metrics:#{user.id}:#{start_date}:#{end_date}:#{product_ids}"
      end
    end

    def fetch_cached_data
      Rails.cache.fetch(cache_key, expires_in: 24.hours) do
        fetch_realtime_data
      end
    end

    def calculate_for_period(period_start, period_end, subscriptions)
      metrics = calculate_period_metrics(period_start, period_end, subscriptions)

      {
        date: period_end,
        customer_churn_rate: metrics[:churn_rate],
        churned_subscribers: metrics[:churned_count],
        churned_mrr_cents: metrics[:churned_mrr]
      }
    end

    def calculate_period_metrics(period_start, period_end, subscriptions)
      active_at_start = 0
      new_subscribers = 0
      churned_subs = []

      subscriptions.each do |sub|
        active_at_start += 1 if active_at_period_start?(sub, period_start)
        new_subscribers += 1 if new_during_period?(sub, period_start, period_end)
        churned_subs << sub if churned_during_period?(sub, period_start, period_end)
      end

      churned_count = churned_subs.count
      churned_mrr = churned_subs.sum { |sub| calculate_mrr_cents(sub) }
      total_base = active_at_start + new_subscribers
      churn_rate = total_base.zero? ? 0.0 : (churned_count.to_f / total_base * 100).round(2)

      {
        churn_rate: churn_rate,
        churned_count: churned_count,
        churned_mrr: churned_mrr
      }
    end

    def active_at_period_start?(subscription, period_start)
      subscription.created_at < period_start &&
        (subscription.deactivated_at.nil? || subscription.deactivated_at >= period_start)
    end

    def new_during_period?(subscription, period_start, period_end)
      subscription.created_at.between?(period_start, period_end)
    end

    def churned_during_period?(subscription, period_start, period_end)
      subscription.deactivated_at&.between?(period_start, period_end)
    end

    def total_subscriber_base
      @total_subscriber_base ||= active_at_start_count + new_subscribers_count
    end

    def active_at_start_count
      @active_at_start_count ||= count_subscriptions(active_at_start_scope)
    end

    def new_subscribers_count
      @new_subscribers_count ||= count_subscriptions(Subscription.where(created_at: start_date..end_date))
    end

    def churned_count
      @churned_count ||= count_subscriptions(Subscription.where(deactivated_at: start_date..end_date))
    end

    def churned_mrr
      @churned_mrr ||= churned_subscriptions.sum { |sub| calculate_mrr_cents(sub) }
    end

    def churned_subscriptions
      @churned_subscriptions ||= fetch_subscriptions(from: start_date, to: end_date)
        .where(deactivated_at: start_date..end_date)
    end

    def count_subscriptions(scope)
      subscription_products.joins(:subscriptions).merge(scope).count
    end

    def calculate_mrr_cents(subscription)
      payment_option = subscription.last_payment_option
      return 0 unless payment_option&.price

      price = payment_option.price
      normalize_to_monthly_revenue(price.price_cents, price.recurrence)
    end

    def normalize_to_monthly_revenue(price_cents, recurrence)
      case recurrence
      when "monthly"
        price_cents
      when "yearly"
        (price_cents / 12.0).round
      when "quarterly"
        (price_cents / 3.0).round
      else
        0
      end
    end

    def subscription_products
      @subscription_products ||= begin
        base_products = user.products.alive.is_recurring_billing
        if @products.present?
          base_products.where(id: @products.map(&:id))
        else
          base_products
        end
      end
    end

    def fetch_subscriptions(from:, to:)
      base_subscription_scope.where("created_at <= ?", to)
                            .where("deactivated_at IS NULL OR deactivated_at >= ?", from)
                            .includes(last_payment_option: :price)
    end

    def base_subscription_scope
      Subscription.where(seller: @user)
                  .where(link_id: subscription_products.select(:id))
    end

    def active_at_start_scope
      Subscription.where("subscriptions.created_at < ?", start_date)
                  .where(
                    "subscriptions.deactivated_at IS NULL OR subscriptions.deactivated_at >= ?",
                    start_date
                  )
    end

    def format_daily_data(daily_results)
      daily_results.map do |record|
        {
          date: record[:date].to_s,
          customer_churn_rate: record[:customer_churn_rate].to_f,
          churned_subscribers: record[:churned_subscribers],
          churned_mrr_cents: record[:churned_mrr_cents]
        }
      end
    end
end
