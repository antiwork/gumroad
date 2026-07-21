# frozen_string_literal: true

class Api::Mobile::AnalyticsController < Api::Mobile::BaseController
  MAX_BY_REFERRAL_DATE_RANGE_DAYS = 365

  before_action -> { doorkeeper_authorize! :creator_api }
  before_action :set_date_range, only: [:by_date, :by_state, :by_referral]
  before_action :clamp_date_range_for_by_referral, only: :by_referral

  rescue_from Faraday::TimeoutError do
    render json: { success: false, message: "Analytics request timed out" }, status: :gateway_timeout
  end

  rescue_from Rack::Timeout::RequestTimeoutException do
    render json: { success: false, message: "Analytics request timed out" }, status: :gateway_timeout
  end

  def data_by_date
    data = SellerMobileAnalyticsService.new(current_resource_owner, range: params[:range], fields: [:sales_count, :purchases], query: params[:query]).process
    render json: data
  end

  def revenue_totals
    data = %w[day week month year].index_with do |range|
      SellerMobileAnalyticsService.new(current_resource_owner, range:).process
    end
    render json: data
  end

  def by_date
    if params[:group_by] == "hour"
      return render json: { error: "Invalid date range." }, status: :bad_request if @end_date < @start_date
      # The limit is on the SPAN between the endpoints (end - start), not the
      # inclusive date count, so explicit dates exactly seven days apart (eight
      # inclusive dates) are allowed. This matches the shared hourly contract:
      # the same > comparison guards AnalyticsController#data_by_referral, the
      # public API (Api::V2::SalesController / SalesSummary), the frontend's
      # canAggregateHourly check, and CreatorAnalytics::Sales itself.
      if (@end_date - @start_date).to_i > CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS
        return render json: { error: "Date range cannot exceed #{CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS} days for the hourly interval." }, status: :bad_request
      end

      # Hourly data bypasses CreatorAnalytics::CachingProxy, which only stores
      # day-keyed data; the guard above bounds the span at
      # MAX_HOURLY_DATE_RANGE_DAYS, so the live Elasticsearch query is cheap.
      hourly = CreatorAnalytics::Web.new(user: current_resource_owner, dates: (@start_date..@end_date).to_a, interval: "hour").by_date
      data = { dates: hourly[:dates_and_months].map { _1[:date] }, by_date: hourly[:by_date] }
    else
      service = CreatorAnalytics::CachingProxy.new(current_resource_owner)
      options = {
        group_by: params.fetch(:group_by, "day"),
        days_without_years: true
      }
      data = service.data_for_dates(@start_date, @end_date, by: :date, options:)
    end
    # IANA time zone identifier (e.g. "America/Los_Angeles") used by the mobile sales
    # chart to compute how much of the seller's current day has elapsed when projecting
    # today's end-of-day sales total.
    render json: data.merge(seller_time_zone: current_resource_owner.timezone_id)
  end

  def by_state
    data = CreatorAnalytics::CachingProxy.new(current_resource_owner).data_for_dates(@start_date, @end_date, by: :state)
    render json: data
  end

  def by_referral
    service = CreatorAnalytics::CachingProxy.new(current_resource_owner)
    options = {
      group_by: params.fetch(:group_by, "day"),
      days_without_years: true
    }
    data = service.data_for_dates(@start_date, @end_date, by: :referral, options:)
    render json: data
  end

  def products
    pagination, records = pagy(current_resource_owner.products_for_creator_analytics, limit_max: nil, limit_param: :items)
    render json: {
      products: records.as_json(original: true, only: [:id]),
      meta: { pagination: PagyPresenter.new(pagination).metadata }
    }
  end

  protected
    def clamp_date_range_for_by_referral
      if (@end_date - @start_date).to_i > MAX_BY_REFERRAL_DATE_RANGE_DAYS
        @start_date = @end_date - MAX_BY_REFERRAL_DATE_RANGE_DAYS.days
      end
    end

    def set_date_range
      if params[:date_range]
        @end_date = ActiveSupport::TimeZone[current_resource_owner.timezone].today
        if params[:date_range] == "all"
          @start_date = GUMROAD_STARTED_DATE
        else
          offset = { "1d" => 0, "1w" => 6, "1m" => 29, "1y" => 364 }.fetch(params[:date_range])
          @start_date = @end_date - offset
        end
      elsif params[:start_date] && params[:end_date]
        @end_date = Date.parse(params[:end_date])
        @start_date = Date.parse(params[:start_date])
      else
        @end_date = ActiveSupport::TimeZone[current_resource_owner.timezone].today.to_date
        @start_date = @end_date - 29
      end
    end
end
