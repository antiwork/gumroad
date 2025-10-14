# frozen_string_literal: true

class CreatorAnalytics::Churn
  def initialize(user:, start_date:, end_date:)
    @user = user
    @start_date = start_date.to_date
    @end_date = end_date.to_date
  end

  def calculate
    {
      date: @end_date,
      customer_churn_rate: customer_churn_rate,
      churned_subscribers: churned_count,
      churned_mrr_cents: churned_mrr
    }
  end

  def calculate_by_date
    earliest_date = @start_date - 29.days

    all_subscriptions = Subscription
      .where(seller: @user)
      .where(link_id: subscription_products.select(:id))
      .where("created_at < ? OR deactivated_at >= ?", @end_date + 1.day, earliest_date)
      .includes(:last_payment_option => :price)
      .to_a

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

  private
    def calculate_for_period(period_start, period_end, subscriptions)
      active_at_start = subscriptions.count do |sub|
        sub.created_at < period_start &&
          (sub.deactivated_at.nil? || sub.deactivated_at >= period_start)
      end

      new_subscribers = subscriptions.count do |sub|
        sub.created_at >= period_start && sub.created_at <= period_end
      end

      churned_subs = subscriptions.select do |sub|
        sub.deactivated_at &&
          sub.deactivated_at >= period_start &&
          sub.deactivated_at <= period_end
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
      @churned_subscriptions ||= Subscription
        .where(seller: @user)
        .where(link_id: subscription_products.select(:id))
        .where(deactivated_at: @start_date..@end_date)
        .includes(:last_payment_option => :price)
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

    def active_at_start_scope
      Subscription.where("subscriptions.created_at < ?", @start_date)
                  .where(
                    "subscriptions.deactivated_at IS NULL OR subscriptions.deactivated_at >= ?",
                    @start_date
                  )
    end
end
