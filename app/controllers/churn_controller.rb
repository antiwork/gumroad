# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  layout "inertia", only: [:show]

  def show
    authorize :churn

    LargeSeller.create_if_warranted(current_seller)

    render inertia: "Churn/Index",
           props: {
             churn_props: {
               has_subscription_products: has_subscription_products?
             },
             churn_data: InertiaRails.optional { lazy_churn_data }
           }
  end

  private
    def has_subscription_products?
      current_seller.products.alive.is_recurring_billing.exists?
    end

    def lazy_churn_data
      return nil unless has_subscription_products?

      set_time_range
      fetch_churn_data
    end

    def set_time_range
      @start_date = params[:start_time]&.to_date || 30.days.ago.to_date
      @end_date = params[:end_time]&.to_date || Date.current

      @start_date = [@start_date, 1.year.ago.to_date].max
    end

    def fetch_churn_data
      if should_use_cache?
        fetch_cached_data
      else
        fetch_realtime_data
      end
    end

    def should_use_cache?
      LargeSeller.where(user: current_seller).exists?
    end

    def cache_key(start_date, end_date)
      "seller_daily_churn_metrics:#{current_seller.id}:#{start_date}:#{end_date}"
    end

    def fetch_cached_data
      cache_key_value = cache_key(@start_date, @end_date)

      cached_data = Rails.cache.fetch(cache_key_value, expires_in: 24.hours) do
        compute_churn_data
      end

      cached_data
    end

    def fetch_realtime_data
      compute_churn_data
    end

    def compute_churn_data
      service = CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: @start_date,
        end_date: @end_date
      )

      result = service.calculate
      daily_results = service.calculate_by_date

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

    def build_metrics(result)
      {
        customer_churn_rate: result[:customer_churn_rate].to_f,
        last_period_churn_rate: last_period_churn_rate.to_f,
        churned_subscribers: result[:churned_subscribers],
        churned_mrr_cents: result[:churned_mrr_cents]
      }
    end

    def last_period_churn_rate
      period_length = (@end_date - @start_date).to_i
      last_period_end = @start_date - 1.day
      last_period_start = last_period_end - period_length.days

      if should_use_cache?
        cache_key_value = cache_key(last_period_start, last_period_end)
        Rails.cache.fetch(cache_key_value, expires_in: 24.hours) do
          calculate_last_period_churn_rate(last_period_start, last_period_end)
        end
      else
        calculate_last_period_churn_rate(last_period_start, last_period_end)
      end
    end

    def calculate_last_period_churn_rate(start_date, end_date)
      CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: start_date,
        end_date: end_date
      ).customer_churn_rate
    end
end
