# frozen_string_literal: true

class AnalyticsController < Sellers::BaseController
  before_action :set_time_range, only: %i[data_by_date data_by_state data_by_referral churn_data churn_summary]
  before_action :set_churn_products, only: %i[churn_data churn_summary]

  after_action :set_dashboard_preference_to_sales, only: :index
  before_action :check_payment_details, only: :index

  layout "inertia", only: [:index, :churn]

  def index
    authorize :analytics

    @analytics_props = AnalyticsPresenter.new(seller: current_seller).page_props
    LargeSeller.create_if_warranted(current_seller)

    render inertia: "Analytics/Index",
           props: { analytics_props: @analytics_props }
  end

  def churn
    authorize :analytics

    subscription_products = current_seller.products_for_creator_analytics.select do |product|
      product.link&.recurrence.present? || product.subscription_duration.present?
    end

    @churn_props = {
      products: subscription_products.map { |p| { id: p.external_id, alive: p.alive?, unique_permalink: p.unique_permalink, name: p.name } },
      has_subscription_products: subscription_products.any?
    }

    render inertia: "Analytics/Churn",
           props: { churn_props: @churn_props }
  end

  def data_by_date
    authorize :analytics, :index?

    if Feature.active?(:use_creator_analytics_web_in_controller)
      data = creator_analytics_web.by_date
    else
      data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :date)
    end
    render json: data
  end

  def data_by_state
    authorize :analytics, :index?

    if Feature.active?(:use_creator_analytics_web_in_controller)
      data = creator_analytics_web.by_state
    else
      data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :state)
    end
    render json: data
  end

  def data_by_referral
    authorize :analytics, :index?

    if Feature.active?(:use_creator_analytics_web_in_controller)
      data = creator_analytics_web.by_referral
    else
      data = CreatorAnalytics::CachingProxy.new(current_seller).data_for_dates(@start_date, @end_date, by: :referral)
    end
    render json: data
  end

  def churn_data
    authorize :analytics, :index?

    return render json: { error: "No subscription products found" }, status: :not_found if @churn_products.empty?

    churn_service = CreatorAnalytics::Churn.new(
      user: current_seller,
      products: @churn_products,
      dates: (@start_date..@end_date).to_a
    )

    data = churn_service.by_product_and_date
    render json: format_churn_data(data)
  end

  def churn_summary
    authorize :analytics, :index?

    churn_service = CreatorAnalytics::Churn.new(
      user: current_seller,
      products: @churn_products,
      dates: (@start_date..@end_date).to_a
    )

    summary = churn_service.summary
    render json: summary
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

    def creator_analytics_web
      CreatorAnalytics::Web.new(user: current_seller, dates: (@start_date .. @end_date).to_a)
    end

    def set_churn_products
      # Only include products with subscription/membership enabled
      @churn_products = current_seller.products_for_creator_analytics.select do |product|
        product.link&.recurrence.present? || product.subscription_duration.present?
      end
    end

    def format_churn_data(data)
      {
        by_product_and_date: data,
        start_date: @start_date.to_s,
        end_date: @end_date.to_s
      }
    end

    def set_title
      @title = "Analytics"
    end
end
