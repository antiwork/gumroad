# frozen_string_literal: true

module Products
  class RichContentAnalyticsController < Sellers::BaseController
    before_action :set_product
    before_action :set_date_range

    def index
      authorize @product, :edit?

      analytics_service = CreatorAnalytics::RichContentPageViews.new(
        product: @product,
        start_date: @start_date,
        end_date: @end_date
      )

      render json: {
        page_stats: analytics_service.page_view_stats,
        total_views: analytics_service.total_views_by_page
      }
    end

    private
      def set_product
        @product = current_seller.products.find_by!(custom_permalink: params[:product_id])
      end

      def set_date_range
        begin
          @end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : Date.current
          @start_date = params[:start_date].present? ? Date.parse(params[:start_date]) : @end_date.ago(29.days)
        rescue ArgumentError
          @end_date = Date.current
          @start_date = @end_date.ago(29.days)
        end
      end
  end
end
