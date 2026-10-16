# frozen_string_literal: true

class DashboardController < Sellers::BaseController
  include ActionView::Helpers::NumberHelper, CurrencyHelper

  before_action :check_payment_details, only: :index

  layout "inertia", only: :index

  FULL_ROLLOUT_PERCENTAGE = 100

  def index
    authorize :dashboard
    session.delete(:social_connect_return)

    if current_seller.suspended_for_tos_violation?
      redirect_to products_url
    else
      LargeSeller.create_if_warranted(current_seller)
      props = log_sales_query_exposure { CreatorHomePresenter.new(pundit_user).creator_home_props }
      SocialConnectFunnel.record_offers!(
        user: current_seller,
        connections: props[:social_connections],
        surface: "getting_started",
        skip: impersonating?,
      )
      render inertia: "Dashboard/Index",
             props: { creator_home: props }
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

  def dismiss_getting_started_checklist
    authorize :dashboard

    current_seller.update!(has_dismissed_getting_started_checklist: true)

    head :ok
  end

  private
    # One line per dashboard load while the flag is mid-ramp. request_uuid joins it to the
    # request's lograge line, which carries the full server time; best_sellers lets the arms be
    # checked for showing the same cards.
    def log_sales_query_exposure
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      props = yield
      percentage = Flipper[CreatorHomePresenter::SALES_QUERY_FLAG].percentage_of_actors_value
      return props unless percentage.positive? && percentage < FULL_ROLLOUT_PERCENTAGE

      Rails.logger.info(
        {
          event: "dashboard_home_sales_query_exposure",
          arm: Feature.active?(CreatorHomePresenter::SALES_QUERY_FLAG, current_seller) ? "treatment" : "control",
          large_seller: LargeSeller.where(user: current_seller).exists?,
          props_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round,
          best_sellers: props[:sales].size,
          request_uuid: request.uuid,
        }.to_json,
      )
      props
    end
end
