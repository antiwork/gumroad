# frozen_string_literal: true

class Products::ContentPageAnalyticsController < Sellers::BaseController
  before_action :set_product
  before_action :set_date_range

  def show
    authorize @product, :edit?

    analytics = CreatorAnalytics::ContentPageViews.new(
      link: @product,
      start_date: @start_date,
      end_date: @end_date
    )

    render json: {
      pages: analytics.by_page,
      total_views: analytics.total_views,
      unique_viewers: analytics.unique_viewers,
      by_page_and_date: analytics.by_page_and_date
    }
  end

  private
    def set_product
      @product = current_seller.links.find_by!(external_id: params[:product_id])
    end

    def set_date_range
      @start_date = params[:start_date].present? ? Date.parse(params[:start_date]) : 30.days.ago.to_date
      @end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : Date.current
    rescue ArgumentError
      @start_date = 30.days.ago.to_date
      @end_date = Date.current
    end
end
