# frozen_string_literal: true

class Api::V2::SalesController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize! :view_sales }
  before_action(only: [:mark_as_shipped]) { doorkeeper_authorize! :mark_sales_as_shipped }
  before_action(only: [:refund]) { doorkeeper_authorize! :refund_sales }
  before_action :set_page, only: :index

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

    email = params[:email].present? ? params[:email].strip : nil

    if params[:product_id].present?
      product_id = ObfuscateIds.decrypt(params[:product_id])

      # The de-obfuscation above will fail silently if invalid base64 string is passed.
      # Here, the user is clearly trying to scope their results to a single product,
      # so we cannot proceed with product_id = nil, or we will return a wider than expected result set.
      return error_400("Invalid product ID.") if product_id.nil?
    end

    if params[:order_id].present?
      return error_400("Invalid order ID.") if params[:order_id].to_i.to_s != params[:order_id]

      purchase_id = ObfuscateIds.decrypt_numeric(params[:order_id].to_i)
    end

    if params[:page] # DEPRECATED
      filtered_sales = filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:, root_scope: current_resource_owner.sales)
      begin
        timeout_s = ($redis.get(RedisKey.api_v2_sales_deprecated_pagination_query_timeout) || 15).to_i
        WithMaxExecutionTime.timeout_queries(seconds: timeout_s) do
          paginated_sales = filtered_sales.for_sales_api.limit(RESULTS_PER_PAGE + 1).offset((@page - 1) * RESULTS_PER_PAGE).to_a
          has_next_page = paginated_sales.size > RESULTS_PER_PAGE
          paginated_sales = paginated_sales.first(RESULTS_PER_PAGE)
          if has_next_page
            success_with_object(:sales, paginated_sales.as_json(version: 2), pagination_info(paginated_sales.last))
          else
            success_with_object(:sales, paginated_sales.as_json(version: 2))
          end
        end
      rescue WithMaxExecutionTime::QueryTimeoutError
        error_400("The 'page' parameter is deprecated. Please use 'page_key' instead: https://gumroad.com/api#sales")
      end
      return
    end

    if params[:page_key].present?
      begin
        last_purchase_created_at, last_purchase_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      where_page_data = ["created_at <= ? and id < ?", last_purchase_created_at, last_purchase_id]
    end

    paginated_sales = filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:)
    subquery_filters = ->(query) {
      query.where(seller_id: current_resource_owner.id).where(where_page_data).order(created_at: :desc, id: :desc).limit(RESULTS_PER_PAGE + 1)
    }
    paginated_sales = paginated_sales.for_sales_api_ordered_by_date(subquery_filters)
    paginated_sales = paginated_sales.limit(RESULTS_PER_PAGE + 1).to_a
    has_next_page = paginated_sales.size > RESULTS_PER_PAGE
    paginated_sales = paginated_sales.first(RESULTS_PER_PAGE)
    additional_response = has_next_page ? pagination_info(paginated_sales.last) : {}
    success_with_object(:sales, paginated_sales.as_json(version: 2), additional_response)
  end

  def show
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    purchase ? success_with_sale(purchase.as_json(version: 2)) : error_with_sale
  end

  def mark_as_shipped
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])

    return error_with_sale if purchase.nil?

    shipment = Shipment.create(purchase:) if purchase.shipment.blank?
    shipment ||= purchase.shipment

    if params[:tracking_url]
      shipment.tracking_url = params[:tracking_url]
      shipment.save!
    end

    shipment.mark_shipped
    success_with_sale(purchase.as_json(version: 2))
  end

  def refund
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    return error_with_sale if purchase.nil?

    if purchase.refunded?
      purchase.errors.add(:base, "Purchase is already refunded.")
      return error_with_sale(purchase)
    end

    amount = params[:amount_cents].to_i / 100.0 if params[:amount_cents].present?

    if purchase.refund!(refunding_user_id: current_resource_owner.id, amount:)
      success_with_sale(purchase.as_json(version: 2))
    else
      error_with_sale(purchase)
    end
  end

  private
    def success_with_sale(sale = nil)
      success_with_object(:sale, sale)
    end

    def error_with_sale(sale = nil)
      error_with_object(:sale, sale)
    end

    def filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:, root_scope: Purchase)
      sales = root_scope
      sales = sales.where("created_at >= ?", start_date) if start_date
      sales = sales.where("created_at < ?", end_date) if end_date
      sales = sales.where(email:) if email.present?
      sales = sales.where(link_id: product_id) if product_id.present?
      sales = sales.where(id: purchase_id) if purchase_id.present?
      sales.order(created_at: :desc, id: :desc)
    end

    def set_page # DEPRECATED
      @page = (params[:page] || 1).to_i
      error_400("Invalid page number. Page numbers start at 1.") unless @page > 0
    end
end
