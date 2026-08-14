# frozen_string_literal: true

class AnalyticsController < Sellers::BaseController
  # Web analytics endpoints run unclamped; this only bounds the public v2 Sales API.
  MAX_DATE_RANGE_DAYS = 366

  before_action :set_time_range, only: %i[data_by_date data_by_state data_by_referral]

  after_action :set_dashboard_preference_to_sales, only: :index
  before_action :check_payment_details, only: :index

  layout "inertia", only: [:index]

  def index
    authorize :analytics

    @analytics_props = AnalyticsPresenter.new(seller: current_seller).page_props
    LargeSeller.create_if_warranted(current_seller)

    render inertia: "Analytics/Index",
           props: { analytics_props: @analytics_props }
  end

  def data_by_date
    authorize :analytics, :index?

    data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :date)
    render json: data
  end

  def data_by_state
    authorize :analytics, :index?

    data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :state)
    render json: data
  end

  def data_by_referral
    authorize :analytics, :index?

    if params[:interval] == "hour"
      return render json: { error: "Invalid date range." }, status: :bad_request if @end_date < @start_date
      if (@end_date - @start_date).to_i > CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS
        return render json: { error: "Date range cannot exceed #{CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS} days for the hourly interval." }, status: :bad_request
      end

      # Hourly data bypasses CreatorAnalytics::CachingProxy, which only stores
      # day-keyed data; the range is at most 7 days so the live query is cheap.
      data = creator_analytics_web(interval: "hour").by_referral
    else
      data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :referral)
    end
    render json: data
  end

  protected
    def set_time_range
      begin
        end_time = DateTime.parse(strip_timestamp_location(params[:end_time]))
        start_date = Date.parse(strip_timestamp_location(params[:start_time]))
      rescue StandardError
        end_time = DateTime.current
        start_date = end_time.to_date.ago(29.days).to_date
      end
      @start_date = start_date
      @end_date = end_time.to_date
    end

    def creator_analytics_web(interval: "day")
      CreatorAnalytics::Web.new(user: current_seller, dates: (@start_date .. @end_date).to_a, interval:)
    end

    def set_default_page_title
      set_meta_tag(title: "Analytics")
    end
end
