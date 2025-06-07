# frozen_string_literal: true

class Api::Mobile::AnalyticsController < Api::Mobile::BaseController
  before_action -> { doorkeeper_authorize! :creator_api }
  before_action :set_date_range, only: [:by_date, :by_state, :by_referral]

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
    service = CreatorAnalytics::CachingProxy.new(current_resource_owner)
    options = {
      group_by: params.fetch(:group_by, "day"),
      days_without_years: true
    }
    data = service.data_for_dates(@start_date, @end_date, by: :date, options:)
    render json: data
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
      products: records.as_json(mobile: true),
      meta: { pagination: PagyPresenter.new(pagination).metadata }
    }
  end

  protected
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
