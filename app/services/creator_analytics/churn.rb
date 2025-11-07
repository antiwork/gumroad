# frozen_string_literal: true

class CreatorAnalytics::Churn
  def initialize(user:, products:, dates:)
    @user = user
    @products = products
    @dates = dates
  end

  # Returns churn data grouped by product and date
  # Formula: (Cancelled subscriptions / (Active at start + New subscriptions)) × 100
  def by_product_and_date
    return {} if @products.empty?

    result = {}

    @products.each do |product|
      @dates.each do |date|
        period_start = date.beginning_of_day
        period_end = date.end_of_day

        # Get subscriptions for this product
        product_subscriptions = base_subscription_scope.where(link_id: product.id)

        # Count active subscriptions at the start of the period
        # NOTE: This uses alive_at? which requires loading records into memory
        # because the logic involves complex subscription state calculations.
        # For better performance with large datasets, consider preloading
        # subscriptions created before period_start once per product.
        active_at_start = product_subscriptions.where(
          "created_at < ?", period_start
        ).select { |sub| sub.alive_at?(period_start) }.count

        # Count new subscriptions created during the period
        new_subscriptions = product_subscriptions.where(
          created_at: period_start..period_end
        ).count

        # Count cancelled subscriptions during the period
        # A subscription is considered churned if it was cancelled, failed, or ended during the period
        cancelled_subscriptions = churned_subscriptions_scope(product_subscriptions, period_start, period_end).count

        # Calculate churn rate
        denominator = active_at_start + new_subscriptions
        churn_rate = denominator > 0 ? (cancelled_subscriptions.to_f / denominator * 100).round(2) : 0.0

        # Calculate revenue lost (sum of MRR for cancelled subscriptions)
        revenue_lost_cents = calculate_revenue_lost(product_subscriptions, period_start, period_end)

        key = [product.id, date.to_s]
        result[key] = {
          churn_rate: churn_rate,
          cancelled_count: cancelled_subscriptions,
          revenue_lost_cents: revenue_lost_cents,
          active_at_start: active_at_start,
          new_subscriptions: new_subscriptions
        }
      end
    end

    result
  end

  # Returns aggregated churn data for the entire period
  def summary
    return default_summary if @products.empty?

    product_ids = @products.map(&:id)
    period_start = @dates.first.beginning_of_day
    period_end = @dates.last.end_of_day

    # Current period metrics
    current_period_data = calculate_period_metrics(product_ids, period_start, period_end)

    # Last period metrics (same duration, just shifted back)
    period_duration = period_end - period_start
    last_period_start = period_start - period_duration
    last_period_end = period_start - 1.second
    last_period_data = calculate_period_metrics(product_ids, last_period_start, last_period_end)

    {
      current_period: current_period_data,
      last_period: last_period_data,
      has_subscription_products: @products.any?,
      start_date: @dates.first.to_s,
      end_date: @dates.last.to_s
    }
  end

  private

  def base_subscription_scope
    Subscription.where(seller_id: @user.id)
                .where.not(is_test_subscription: true)
  end

  # Extracts churned subscriptions scope for a given period
  # This eliminates duplicate SQL logic across methods
  def churned_subscriptions_scope(subscriptions_scope, period_start, period_end)
    subscriptions_scope.where(
      "((cancelled_at >= ? AND cancelled_at <= ?) OR " \
      "(failed_at >= ? AND failed_at <= ?) OR " \
      "(ended_at >= ? AND ended_at <= ?) OR " \
      "(deactivated_at >= ? AND deactivated_at <= ?))",
      period_start, period_end,
      period_start, period_end,
      period_start, period_end,
      period_start, period_end
    )
  end

  def calculate_revenue_lost(subscriptions_scope, period_start, period_end)
    churned_subs = churned_subscriptions_scope(subscriptions_scope, period_start, period_end)
    churned_subs.sum { |sub| sub.price || 0 }
  end

  def calculate_period_metrics(product_ids, period_start, period_end)
    product_subscriptions = base_subscription_scope.where(link_id: product_ids)

    # Active at start of period
    # NOTE: Uses alive_at? which loads records into memory for complex state checks
    active_at_start = product_subscriptions.where(
      "created_at < ?", period_start
    ).select { |sub| sub.alive_at?(period_start) }.count

    # New subscriptions in period
    new_subscriptions = product_subscriptions.where(
      created_at: period_start..period_end
    ).count

    # Cancelled subscriptions in period
    cancelled_subscriptions = churned_subscriptions_scope(product_subscriptions, period_start, period_end).count

    # Calculate churn rate
    denominator = active_at_start + new_subscriptions
    churn_rate = denominator > 0 ? (cancelled_subscriptions.to_f / denominator * 100).round(2) : 0.0

    # Revenue lost
    revenue_lost_cents = calculate_revenue_lost(product_subscriptions, period_start, period_end)

    {
      churn_rate: churn_rate,
      churned_users: cancelled_subscriptions,
      revenue_lost_cents: revenue_lost_cents,
      active_at_start: active_at_start,
      new_subscriptions: new_subscriptions
    }
  end

  def default_summary
    {
      current_period: {
        churn_rate: 0.0,
        churned_users: 0,
        revenue_lost_cents: 0,
        active_at_start: 0,
        new_subscriptions: 0
      },
      last_period: {
        churn_rate: 0.0,
        churned_users: 0,
        revenue_lost_cents: 0,
        active_at_start: 0,
        new_subscriptions: 0
      },
      has_subscription_products: false,
      start_date: @dates.first.to_s,
      end_date: @dates.last.to_s
    }
  end
end
