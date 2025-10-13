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
    dates_array = (@start_date..@end_date).to_a
    dates_array.map do |date|
      period_start = date - 29.days
      period_end = date

      self.class.new(user: @user, start_date: period_start, end_date: period_end).calculate
    end
  end

  def customer_churn_rate
    return 0.0 if total_subscriber_base.zero?
    (churned_count.to_f / total_subscriber_base * 100).round(2)
  end

  private
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
      @churned_subscriptions ||= subscription_products
        .joins(:subscriptions)
        .merge(Subscription.where(deactivated_at: @start_date..@end_date))
        .includes(subscriptions: { last_payment_option: :price })
        .flat_map(&:subscriptions)
        .select { |s| s.deactivated_at&.between?(@start_date, @end_date) }
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

