# frozen_string_literal: true

class Api::V2::PayoutsController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(:view_payouts) }

  RESULTS_PER_PAGE = 10

  def index
    begin
      end_date = Date.strptime(params[:before], "%Y-%m-%d") if params[:before]
    rescue ArgumentError
      return error_400("Invalid date format provided in field 'before'. Dates must be in the format YYYY-MM-DD.")
    end

    begin
      start_date = Date.strptime(params[:after], "%Y-%m-%d") if params[:after]
    rescue ArgumentError
      return error_400("Invalid date format provided in field 'after'. Dates must be in the format YYYY-MM-DD.")
    end

    if params[:page_key].present?
      begin
        last_payout_created_at, last_payout_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      where_page_data = ["(created_at < ?) OR (created_at = ? AND id < ?)", last_payout_created_at, last_payout_created_at, last_payout_id]
    end

    paginated_payouts = filter_payouts(start_date: start_date, end_date: end_date)
    paginated_payouts = paginated_payouts.where(where_page_data) if where_page_data
    paginated_payouts = paginated_payouts.limit(RESULTS_PER_PAGE + 1).to_a

    has_next_page = paginated_payouts.size > RESULTS_PER_PAGE
    paginated_payouts = paginated_payouts.first(RESULTS_PER_PAGE)
    additional_response = has_next_page ? pagination_info(paginated_payouts.last) : {}

    success_with_object(:payouts, paginated_payouts.as_json, additional_response)
  end

  def show
    payout = current_resource_owner.payments.find_by_external_id(params[:id])
    if payout
      include_sales = doorkeeper_token.scopes.include?("view_sales")
      success_with_payout(payout.as_json(include_sales: include_sales))
    else
      error_with_payout
    end
  end

  private
    def success_with_payout(payout = nil)
      success_with_object(:payout, payout)
    end

    def error_with_payout(payout = nil)
      error_with_object(:payout, payout)
    end

    def filter_payouts(start_date:, end_date:)
      payouts = current_resource_owner.payments.displayable
      payouts = payouts.where("created_at >= ?", start_date) if start_date
      payouts = payouts.where("created_at < ?", end_date) if end_date
      payouts.order(created_at: :desc, id: :desc)
    end
end
