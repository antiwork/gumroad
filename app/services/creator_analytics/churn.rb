# frozen_string_literal: true

# Calculates customer churn rate metrics for subscription products.
#
# Churn rate formula (per Stripe):
#   (Churned Customers / Total Base Customers) × 100
#
# Where Total Base = Active at Start + New During Period
#
# @see https://stripe.com/resources/more/monthly-churn-101
class CreatorAnalytics::Churn
  include ActiveModel::Validations

  DEFAULT_START_DATE_OFFSET = 1.month
  CACHE_EXPIRY = 24.hours

  validates :end_date, comparison: { greater_than_or_equal_to: :start_date }

  attr_reader :start_date, :end_date, :user, :products

  def initialize(user:, start_date: nil, end_date: nil, params: {}, products: nil)
    @user = user
    @params = params
    @start_date = parse_date(start_date, :start)
    @end_date = parse_date(end_date, :end)
    @products = products || parse_products
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

  def time_window
    (end_date - start_date).to_i + 1
  end

  def self.customer_churn_rate(user:, start_date:, end_date:, products: nil)
    new(
      user: user,
      start_date: start_date,
      end_date: end_date,
      products: products
    ).send(:calculate_churn_rate)
  end

  private
    def fetch_realtime_data
      raise ArgumentError, "Invalid date range: #{errors.full_messages.join(', ')}" unless valid?

      subs = subscriptions_for_period
      period_metrics = calculate_period_metrics(start_date, end_date, subs)
      daily_results = build_daily_results(subs)
      last_period_rate = calculate_last_period_churn_rate

      {
        start_date: start_date.to_s,
        end_date: end_date.to_s,
        metrics: build_metrics(period_metrics, last_period_rate),
        daily_data: format_daily_data(daily_results)
      }
    end

    def fetch_cached_data
      Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
        fetch_realtime_data
      end
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

    def subscriptions_for_period
      @subscriptions_for_period ||= fetch_subscriptions(from: start_date, to: end_date).load
    end

    def build_daily_results(subscriptions)
      (start_date..end_date).map do |date|
        metrics = calculate_period_metrics(date, date, subscriptions)

        {
          date: date,
          customer_churn_rate: metrics[:churn_rate],
          churned_subscribers: metrics[:churned_subscribers],
          churned_mrr_cents: metrics[:churned_mrr_cents],
          active_at_start: metrics[:active_at_start],
          new_subscribers: metrics[:new_subscribers]
        }
      end
    end

    def calculate_churn_rate
      metrics = calculate_period_metrics(start_date, end_date, subscriptions_for_period)
      metrics[:churn_rate]
    end

    def calculate_period_metrics(period_start, period_end, subscriptions)
      active_at_start = 0
      new_subscribers = 0
      churned_subscribers = 0
      churned_mrr_cents = 0

      subscriptions.each do |sub|
        active_at_start += 1 if active_at_period_start?(sub, period_start)
        new_subscribers += 1 if new_during_period?(sub, period_start, period_end)

        if churned_during_period?(sub, period_start, period_end)
          churned_subscribers += 1
          churned_mrr_cents += calculate_mrr_cents(sub)
        end
      end

      total_base = active_at_start + new_subscribers
      churn_rate = total_base.zero? ? 0.0 : (churned_subscribers.to_f / total_base * 100).round(2)

      {
        churn_rate: churn_rate,
        churned_subscribers: churned_subscribers,
        churned_mrr_cents: churned_mrr_cents,
        total_base: total_base,
        active_at_start: active_at_start,
        new_subscribers: new_subscribers
      }
    end

    def calculate_last_period_churn_rate
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

    def active_at_period_start?(subscription, period_start)
      subscription.created_at < period_start &&
        (subscription.deactivated_at.nil? || subscription.deactivated_at >= period_start)
    end

    def new_during_period?(subscription, period_start, period_end)
      subscription.created_at.between?(period_start.beginning_of_day, period_end.end_of_day)
    end

    def churned_during_period?(subscription, period_start, period_end)
      subscription.deactivated_at&.between?(period_start.beginning_of_day, period_end.end_of_day)
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

    def build_metrics(period_metrics, last_period_rate)
      {
        customer_churn_rate: period_metrics[:churn_rate],
        last_period_churn_rate: last_period_rate,
        churned_subscribers: period_metrics[:churned_subscribers],
        churned_mrr_cents: period_metrics[:churned_mrr_cents]
      }
    end

    def format_daily_data(daily_results)
      daily_results.map do |record|
        date = record[:date]
        {
          date: date.to_s,
          month: date.strftime("%B %Y"),
          month_index: ((date.year - start_date.year) * 12) + (date.month - start_date.month),
          customer_churn_rate: record[:customer_churn_rate],
          churned_subscribers: record[:churned_subscribers],
          churned_mrr_cents: record[:churned_mrr_cents],
          active_at_start: record[:active_at_start],
          new_subscribers: record[:new_subscribers]
        }
      end
    end

    def parse_date(date_value, type)
      return date_value.to_date if date_value

      case type
      when :start
        (@params[:start_time] || @params[:from])&.to_date || DEFAULT_START_DATE_OFFSET.ago.to_date
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
end
