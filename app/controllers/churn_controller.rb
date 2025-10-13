# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  before_action :set_time_range, only: [:data]

  layout "inertia", only: [:index]

  def index
    authorize :churn

    @churn_props = ChurnPresenter.new(seller: current_seller).page_props
    LargeSeller.create_if_warranted(current_seller)

    render inertia: "Churn/Index",
           props: { churn_props: @churn_props }
  end

  def data
    authorize :churn, :index?

    data = fetch_churn_data
    render json: data
  end

  protected
    def set_time_range
      @start_date = params[:start_time]&.to_date || 30.days.ago.to_date
      @end_date = params[:end_time]&.to_date || Date.current

      @start_date = [@start_date, 1.year.ago.to_date].max
    end

  private
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

    def fetch_cached_data
      cached_records = CreatorAnalyticsChurnCache
        .where(user_id: current_seller.id)
        .where(date: @start_date..@end_date)
        .order(:date)

      if cached_records.empty?
        fetch_realtime_data
      else
        format_cached_data(cached_records)
      end
    end

    def fetch_realtime_data
      service = CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: @start_date,
        end_date: @end_date
      )

      result = service.calculate_essential

      period_length = (@end_date - @start_date).to_i
      last_period_end = @start_date - 1.day
      last_period_start = last_period_end - period_length.days

      last_period_service = CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: last_period_start,
        end_date: last_period_end
      )
      last_period_churn_rate = last_period_service.customer_churn_rate

      {
        start_date: @start_date.to_s,
        end_date: @end_date.to_s,
        metrics: {
          customer_churn_rate: result[:customer_churn_rate],
          last_period_churn_rate: last_period_churn_rate,
          churned_subscribers: result[:churned_subscribers],
          churned_mrr_cents: result[:churned_mrr_cents]
        },
        daily_data: service.calculate_by_date_essential
      }
    end

    def format_cached_data(cached_records)
      service = CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: @start_date,
        end_date: @end_date
      )

      overall_metrics = service.calculate_essential

      period_length = (@end_date - @start_date).to_i
      last_period_end = @start_date - 1.day
      last_period_start = last_period_end - period_length.days

      last_period_service = CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: last_period_start,
        end_date: last_period_end
      )
      last_period_churn_rate = last_period_service.customer_churn_rate

      {
        start_date: @start_date.to_s,
        end_date: @end_date.to_s,
        metrics: {
          customer_churn_rate: overall_metrics[:customer_churn_rate],
          last_period_churn_rate: last_period_churn_rate,
          churned_subscribers: overall_metrics[:churned_subscribers],
          churned_mrr_cents: overall_metrics[:churned_mrr_cents]
        },
        daily_data: cached_records.map do |record|
          {
            date: record.date,
            customer_churn_rate: record.customer_churn_rate,
            churned_subscribers: record.churned_subscribers,
            churned_mrr_cents: record.churned_mrr_cents
          }
        end
      }
    end
end

