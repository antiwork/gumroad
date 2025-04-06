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
      @creator_home_props = presenter.creator_home_props

      # Initialize variables needed for the ProductPageView search
      buckets = []
      after_key = nil
      body = {
        aggs: {
          composite_agg: {
            composite: {
              size: 10,
              sources: [
                { product_id: { terms: { field: "product_id" } } }
              ]
            }
          }
        }
      }

      # Add error handling for Elasticsearch operations
      begin
        # Perform the Elasticsearch query with error handling
        loop do
          body[:aggs][:composite_agg][:after] = after_key if after_key
          response_agg = ProductPageView.search(body).aggregations.composite_agg
          buckets += response_agg.buckets
          break if response_agg.buckets.size < 10 # ES_MAX_BUCKET_SIZE
          after_key = response_agg["after_key"]
        end
      rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
        # Handle missing index error
        Rails.logger.warn "Elasticsearch index not found: #{e.message}"
        buckets = [] # Use empty buckets to avoid nil errors
        flash.now[:warning] = "Some analytics data is not available. The system is still initializing."
      rescue => e
        # Handle other Elasticsearch errors
        Rails.logger.error "Elasticsearch error: #{e.message}"
        buckets = [] # Use empty buckets to avoid nil errors
        flash.now[:error] = "There was an error loading analytics data. Please try again later."
      end

      # Make the buckets available to the view if needed
      @page_view_buckets = buckets
    end
  end

  def customers_count
    authorize :dashboard

    begin
      count = current_seller.all_sales_count
      render json: { success: true, value: number_with_delimiter(count) }
    rescue => e
      Rails.logger.error "Error in customers_count: #{e.message}"
      render json: { success: false, value: "0", error: "Could not load data" }
    end
  end

  def total_revenue
    authorize :dashboard

    begin
      revenue = current_seller.gross_sales_cents_total_as_seller
      render json: { success: true, value: formatted_dollar_amount(revenue) }
    rescue => e
      Rails.logger.error "Error in total_revenue: #{e.message}"
      render json: { success: false, value: "$0", error: "Could not load data" }
    end
  end

  def active_members_count
    authorize :dashboard

    begin
      count = current_seller.active_members_count
      render json: { success: true, value: number_with_delimiter(count) }
    rescue => e
      Rails.logger.error "Error in active_members_count: #{e.message}"
      render json: { success: false, value: "0", error: "Could not load data" }
    end
  end

  def monthly_recurring_revenue
    authorize :dashboard

    begin
      revenue = current_seller.monthly_recurring_revenue
      render json: { success: true, value: formatted_dollar_amount(revenue) }
    rescue => e
      Rails.logger.error "Error in monthly_recurring_revenue: #{e.message}"
      render json: { success: false, value: "$0", error: "Could not load data" }
    end
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
