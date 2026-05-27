# frozen_string_literal: true

class Api::V2::SubscribersController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(:view_sales) }
  before_action :fetch_product, only: :index

  RESULTS_PER_PAGE = 100

  def index
    subscriptions = Subscription.where(link_id: @product.id).active
    if params[:email].present?
      # Email-filter via a join-based id subquery rather than chaining
      # `.where(purchases: { email: })` onto the includes-loaded relation.
      # The chained form switches Rails from `preload` → `eager_load`
      # (LEFT OUTER JOIN), which restricts the in-memory `purchases`
      # association to email-matched rows only — corrupting downstream
      # callers (`Subscription#purchases_for_sales_api_ids`,
      # `#pending_failure?`) that expect every purchase on the subscription.
      email = params[:email].strip
      matched_ids = subscriptions.joins(:purchases).where(purchases: { email: }).distinct.pluck(:id)
      subscriptions = Subscription.where(id: matched_ids)
    end
    subscriptions = subscriptions.includes(:link, :user, :purchases, :original_purchase, :true_original_purchase, last_payment_option: [:price]).order(created_at: :desc, id: :desc)

    if params[:page_key].present?
      begin
        last_record_created_at, last_record_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      subscriptions = subscriptions.where("created_at <= ? and id < ?", last_record_created_at, last_record_id)
    end

    if params[:paginated].in?(["1", "true"]) || params[:page_key].present?
      paginated_subscriptions = subscriptions.limit(RESULTS_PER_PAGE + 1).to_a
      has_next_page = paginated_subscriptions.size > RESULTS_PER_PAGE
      paginated_subscriptions = paginated_subscriptions.first(RESULTS_PER_PAGE)
      additional_response = has_next_page ? pagination_info(paginated_subscriptions.last) : {}

      success_with_object(:subscribers, paginated_subscriptions, additional_response)
    else
      success_with_object(:subscribers, subscriptions)
    end
  end

  def show
    subscription = Subscription.find_by_external_id(params[:id])
    if subscription && subscription.link.user == current_resource_owner
      success_with_subscription(subscription)
    else
      error_with_subscription
    end
  end

  private
    def success_with_subscription(subscription = nil)
      success_with_object(:subscriber, subscription)
    end

    def error_with_subscription(subscription = nil)
      error_with_object(:subscriber, subscription)
    end
end
