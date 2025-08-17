# frozen_string_literal: true

class DashboardController < Sellers::BaseController
  include ActionView::Helpers::NumberHelper, CurrencyHelper
  skip_before_action :check_suspended
  before_action :check_payment_details, only: :index

  def index
    authorize :dashboard

    if current_seller.suspended_for_tos_violation?
      respond_to do |format|
        format.html { redirect_to products_url }
        format.json { render json: { error: "Account suspended", redirect: products_url }, status: :forbidden }
      end
      return
    end

    # Render dashboard
    render_dashboard
  end

  def customers_count
    authorize :dashboard

    count = current_seller.all_sales_count
    render json: { success: true, value: number_with_delimiter(count) }
  end

  def total_revenue
    authorize :dashboard

    revenue = current_seller.gross_sales_cents_total_as_seller
    render json: { success: true, value: formatted_dollar_amount(revenue) }
  end

  def active_members_count
    authorize :dashboard

    count = current_seller.active_members_count
    render json: { success: true, value: number_with_delimiter(count) }
  end

  def monthly_recurring_revenue
    authorize :dashboard

    revenue = current_seller.monthly_recurring_revenue
    render json: { success: true, value: formatted_dollar_amount(revenue) }
  end

  def download_tax_form
    authorize :dashboard

    year = Time.current.year - 1
    tax_form_download_url = current_seller.tax_form_1099_download_url(year:)
    return redirect_to tax_form_download_url, allow_other_host: true if tax_form_download_url.present?

    flash[:alert] = "A 1099 form for #{year} was not filed for your account."
    redirect_to dashboard_path
  end

  def spa
    # Legacy route - redirect to main dashboard
    redirect_to dashboard_path
  end

  private

  def render_dashboard
    respond_to do |format|
      format.html # Will render index.html.erb by default
      format.json { render json: dashboard_api_data }
    end
  end

  def dashboard_api_data
    # API data structure for SPA
    presenter = CreatorHomePresenter.new(pundit_user)
    {
      success: true,
      user: {
        id: current_seller.id,
        name: current_seller.name,
        email: current_seller.email,
        avatar_url: current_seller.profile_picture_url
      },
      dashboard_data: presenter.creator_home_props
    }
  end
end
