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

      return fetch_realtime_data if cached_records.empty?

      format_cached_data(cached_records)
    end

    def fetch_realtime_data
      service = current_period_service
      result = service.calculate_essential

      {
        start_date: @start_date.to_s,
        end_date: @end_date.to_s,
        metrics: build_metrics(result),
        daily_data: service.calculate_by_date_essential.map do |record|
          record.merge(customer_churn_rate: record[:customer_churn_rate].to_f)
        end
      }
    end

    def format_cached_data(cached_records)
      overall_metrics = current_period_service.calculate_essential

      {
        start_date: @start_date.to_s,
        end_date: @end_date.to_s,
        metrics: build_metrics(overall_metrics),
        daily_data: cached_records.map do |record|
          {
            date: record.date.to_s,
            customer_churn_rate: record.customer_churn_rate.to_f,
            churned_subscribers: record.churned_subscribers,
            churned_mrr_cents: record.churned_mrr_cents
          }
        end
      }
    end

    def current_period_service
      @current_period_service ||= CreatorAnalytics::Churn.new(
        user: current_seller,
        start_date: @start_date,
        end_date: @end_date
      )
    end

    def last_period_churn_rate
      @last_period_churn_rate ||= begin
        period_length = (@end_date - @start_date).to_i
        last_period_end = @start_date - 1.day
        last_period_start = last_period_end - period_length.days

        CreatorAnalytics::Churn.new(
          user: current_seller,
          start_date: last_period_start,
          end_date: last_period_end
        ).customer_churn_rate
      end
    end

    def build_metrics(result)
      {
        customer_churn_rate: result[:customer_churn_rate].to_f,
        last_period_churn_rate: last_period_churn_rate.to_f,
        churned_subscribers: result[:churned_subscribers],
        churned_mrr_cents: result[:churned_mrr_cents]
      }
    end
end

