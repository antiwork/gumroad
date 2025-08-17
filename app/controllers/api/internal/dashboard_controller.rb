# frozen_string_literal: true

class Api::Internal::DashboardController < Api::Internal::BaseController
  include ActionView::Helpers::NumberHelper, CurrencyHelper
  
  before_action :check_payment_details, only: :index

  def index
    authorize :dashboard

    if current_seller.suspended_for_tos_violation?
      render json: { error: "Account suspended", redirect: products_url }, status: :forbidden
      return
    end

    presenter = CreatorHomePresenter.new(pundit_user)
    creator_home_props = presenter.creator_home_props

    render json: {
      success: true,
      data: creator_home_props
    }
  end

  def stats
    authorize :dashboard

    stats = {
      customers_count: number_with_delimiter(current_seller.all_sales_count),
      total_revenue: formatted_dollar_amount(current_seller.gross_sales_cents_total_as_seller),
      active_members_count: number_with_delimiter(current_seller.active_members_count),
      monthly_recurring_revenue: formatted_dollar_amount(current_seller.monthly_recurring_revenue)
    }

    render json: { success: true, data: stats }
  end

  def quick_stats
    authorize :dashboard

    # Return just the essential stats for real-time updates
    render json: {
      success: true,
      data: {
        balance: current_seller.balance_formatted,
        pending_balance: current_seller.pending_balance_formatted,
        last_updated: Time.current.iso8601
      }
    }
  end
end