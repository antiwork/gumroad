# frozen_string_literal: true

class DashboardController < Sellers::BaseController
  include ActionView::Helpers::NumberHelper, CurrencyHelper
  skip_before_action :check_suspended
  before_action :check_payment_details, only: :index

  def index
    authorize :dashboard

    if current_seller.suspended_for_tos_violation?
      redirect_to products_url
    else
      presenter = CreatorHomePresenter.new(pundit_user)
      render inertia: "Dashboard/index",
             props: { creator_home: presenter.creator_home_props }
    end
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
end
