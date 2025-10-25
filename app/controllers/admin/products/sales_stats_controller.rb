# frozen_string_literal: true

class Admin::Products::SalesStatsController < Admin::Products::BaseController
  def index
    render json: {
      sales_stats: {
        preorder_state: @product.is_in_preorder_state,
        count: @product.is_in_preorder_state ? @product.sales.preorder_authorization_successful.count : @product.sales.successful.count,
        stripe_failed_count: @product.sales.preorder_authorization_failed.stripe_failed.count,
        balance_formatted: @product.balance_formatted
      }
    }
  end
end
