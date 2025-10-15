# frozen_string_literal: true

class CreatorAnalytics::Churn
  include ActiveModel::Validations

  validates :end_date, comparison: { greater_than: :start_date }
  validates :time_window, inclusion: { in: 1..30, message: "must be between 1 and 30 days" }

  def initialize(user:, start_date: nil, end_date: nil, params: {})
    @user = user
    @params = params
    @start_date = (start_date || parse_start_date).to_date
    @end_date = (end_date || parse_end_date).to_date
  end

  def time_window
    (@end_date - @start_date).to_i + 1
  end

  def calculate
    {
      date: @end_date,
      customer_churn_rate: customer_churn_rate,
      churned_subscribers: churned_count,
      churned_mrr_cents: churned_mrr
    }
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
    @user.products.alive.is_recurring_billing.exists?
  end

  def calculate_by_date
    earliest_date = @start_date - 29.days
    all_subscriptions = fetch_subscriptions(from: earliest_date, to: @end_date)

    (@start_date..@end_date).map do |date|
      period_start = date - 29.days
      period_end = date

      calculate_for_period(period_start, period_end, all_subscriptions)
    end
  end

  def customer_churn_rate
    return 0.0 if total_subscriber_base.zero?
    (churned_count.to_f / total_subscriber_base * 100).round(2)
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
    unless valid?
      return {
        error: "Invalid date range: #{errors.full_messages.join(', ')}"
      }
    end

    result = calculate
    daily_results = calculate_by_date

    daily_data = daily_results.map do |record|
      {
        date: record[:date].to_s,
        customer_churn_rate: record[:customer_churn_rate].to_f,
        churned_subscribers: record[:churned_subscribers],
        churned_mrr_cents: record[:churned_mrr_cents]
      }
    end

    {
      start_date: @start_date.to_s,
      end_date: @end_date.to_s,
      metrics: build_metrics(result),
      daily_data: daily_data
    }
  end

  def last_period_churn_rate
    period_length = (@end_date - @start_date).to_i
    last_period_end = @start_date - 1.day
    last_period_start = last_period_end - period_length.days

    CreatorAnalytics::Churn.new(
      user: @user,
      start_date: last_period_start,
      end_date: last_period_end
    ).customer_churn_rate
  end

  private
    def parse_start_date
      @params[:start_time]&.to_date || 30.days.ago.to_date
    end

    def parse_end_date
      @params[:end_time]&.to_date || Date.current
    end

    def should_use_cache?
      LargeSeller.where(user: @user).exists?
    end

    def cache_key
      "seller_daily_churn_metrics:#{@user.id}:#{@start_date}:#{@end_date}"
    end

    def fetch_cached_data
      Rails.cache.fetch(cache_key, expires_in: 24.hours) do
        fetch_realtime_data
      end
    end

    def calculate_for_period(period_start, period_end, subscriptions)
      active_at_start = 0
      new_subscribers = 0
      churned_subs = []

      subscriptions.each do |sub|
        if sub.created_at < period_start &&
           (sub.deactivated_at.nil? || sub.deactivated_at >= period_start)
          active_at_start += 1
        end

        if sub.created_at >= period_start && sub.created_at <= period_end
          new_subscribers += 1
        end

        if sub.deactivated_at &&
           sub.deactivated_at >= period_start &&
           sub.deactivated_at <= period_end
          churned_subs << sub
        end
      end

      churned_count = churned_subs.count
      churned_mrr = churned_subs.sum { |sub| calculate_mrr_cents(sub) }

      total_base = active_at_start + new_subscribers
      churn_rate = total_base.zero? ? 0.0 : (churned_count.to_f / total_base * 100).round(2)

      {
        date: period_end,
        customer_churn_rate: churn_rate,
        churned_subscribers: churned_count,
        churned_mrr_cents: churned_mrr
      }
    end

    def total_subscriber_base
      @total_subscriber_base ||= active_at_start_count + new_subscribers_count
    end

    def active_at_start_count
      @active_at_start_count ||= subscription_products
        .joins(:subscriptions)
        .merge(active_at_start_scope)
        .count
    end

    def new_subscribers_count
      @new_subscribers_count ||= subscription_products
        .joins(:subscriptions)
        .merge(Subscription.where(created_at: @start_date..@end_date))
        .count
    end

    def churned_count
      @churned_count ||= subscription_products
        .joins(:subscriptions)
        .merge(Subscription.where(deactivated_at: @start_date..@end_date))
        .count
    end

    def churned_mrr
      @churned_mrr ||= churned_subscriptions.sum do |subscription|
        calculate_mrr_cents(subscription)
      end
    end

    def churned_subscriptions
      @churned_subscriptions ||= fetch_subscriptions(from: @start_date, to: @end_date)
        .where(deactivated_at: @start_date..@end_date)
    end

    def calculate_mrr_cents(subscription)
      payment_option = subscription.last_payment_option
      return 0 unless payment_option&.price

      price = payment_option.price

      case price.recurrence
      when "monthly"
        price.price_cents
      when "yearly"
        (price.price_cents / 12.0).round
      when "quarterly"
        (price.price_cents / 3.0).round
      else
        0
      end
    end

    def subscription_products
      @subscription_products ||= @user.products.alive.is_recurring_billing
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
      Subscription.where("subscriptions.created_at < ?", @start_date)
                  .where(
                    "subscriptions.deactivated_at IS NULL OR subscriptions.deactivated_at >= ?",
                    @start_date
                  )
    end
end
