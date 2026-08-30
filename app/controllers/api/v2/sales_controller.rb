# frozen_string_literal: true

class Api::V2::SalesController < Api::V2::BaseController
  include CurrencyHelper
  before_action(only: [:index, :show, :export, :summary]) { doorkeeper_authorize! :view_sales }
  before_action(only: [:mark_as_shipped]) { doorkeeper_authorize! :mark_sales_as_shipped }
  before_action(only: [:refund]) { doorkeeper_authorize! :refund_sales, :edit_sales }
  before_action(only: [:resend_receipt, :revoke_access, :undo_revoke_access]) { doorkeeper_authorize! :edit_sales }
  # BaseController appends the legacy `account` scope to doorkeeper_authorize!.
  # Revoking buyer access must require the seller's explicit edit_sales grant.
  before_action(only: [:revoke_access, :undo_revoke_access]) { require_oauth_scope! :edit_sales }
  before_action :set_page, only: :index

  RESULTS_PER_PAGE = 10
  SALES_API_PRELOADS = [
    :preorder,
    :subscription,
    :tip,
    :utm_link,
    # buyer_presentment fields (v2): presentment row + its charge_presentment (fx_rate)
    # and refunds (in-memory presentment refunded sum) — avoids per-sale queries.
    :refunds,
    { purchase_presentment: :charge_presentment },
    { order: { cart: { sent_abandoned_cart_emails: :installment } } },
  ].freeze

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
    name = params[:name].present? ? params[:name].strip : nil
    license_key = params[:license_key].present? ? params[:license_key].strip : nil

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
      filtered_sales = filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:, name:, license_key:, root_scope: current_resource_owner.sales)
      begin
        timeout_s = ($redis.get(RedisKey.api_v2_sales_deprecated_pagination_query_timeout) || 15).to_i
        WithMaxExecutionTime.timeout_queries(seconds: timeout_s) do
          paginated_sales = filtered_sales.for_sales_api.preload(*SALES_API_PRELOADS).limit(RESULTS_PER_PAGE + 1).offset((@page - 1) * RESULTS_PER_PAGE).to_a
          has_next_page = paginated_sales.size > RESULTS_PER_PAGE
          paginated_sales = paginated_sales.first(RESULTS_PER_PAGE)
          if has_next_page
            success_with_object(:sales, paginated_sales.as_json(version: 2, include_buyer_presentment: true), pagination_info(paginated_sales.last))
          else
            success_with_object(:sales, paginated_sales.as_json(version: 2, include_buyer_presentment: true))
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

    # Guard the main (page_key) pagination path with a query timeout, mirroring the
    # protection on the deprecated `page` path above. The underlying
    # `for_sales_api_ordered_by_date` UNION query can run for minutes on very large
    # accounts with broad filters; without this guard the request runs until
    # Rack::Timeout kills the worker process at 120s.
    begin
      timeout_s = ($redis.get(RedisKey.api_v2_sales_page_key_query_timeout) || 15).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_s) do
        paginated_sales = filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:, name:, license_key:)
        subquery_filters = ->(query) {
          query.where(seller_id: current_resource_owner.id).where(where_page_data).order(created_at: :desc, id: :desc).limit(RESULTS_PER_PAGE + 1)
        }
        paginated_sales = paginated_sales.for_sales_api_ordered_by_date(subquery_filters)
        paginated_sales = paginated_sales.preload(*SALES_API_PRELOADS)
        paginated_sales = paginated_sales.limit(RESULTS_PER_PAGE + 1).to_a
        has_next_page = paginated_sales.size > RESULTS_PER_PAGE
        paginated_sales = paginated_sales.first(RESULTS_PER_PAGE)
        additional_response = has_next_page ? pagination_info(paginated_sales.last) : {}
        success_with_object(:sales, paginated_sales.as_json(version: 2, include_buyer_presentment: true), additional_response)
      end
    rescue WithMaxExecutionTime::QueryTimeoutError
      error_400("Query timed out. Try narrowing your date range with 'after'/'before' or filtering by product_id.")
    end
  end

  def show
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    purchase ? success_with_sale(purchase.as_json(version: 2, include_buyer_presentment: true)) : error_with_sale
  end

  def export
    filters = export_filters
    return if performed?

    Exports::PurchaseExportService.export(
      seller: current_resource_owner,
      recipient: current_resource_owner,
      filters:,
      force_async: true
    )
    render_response(true, status: "queued", recipient_email: current_resource_owner.email)
  end

  def summary
    summary_params = sales_summary_params
    return if performed?

    render_response(true, Api::V2::SalesSummary.new(seller: current_resource_owner, **summary_params))
  end

  def mark_as_shipped
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])

    return error_with_sale if purchase.nil?

    shipment = purchase.shipment || Shipment.new(purchase:)

    if params.key?(:tracking_url)
      shipment.tracking_url = params[:tracking_url]
    end

    return error_with_sale(shipment) unless shipment.save

    shipment.mark_shipped
    success_with_sale(purchase.as_json(version: 2, include_buyer_presentment: true))
  end

  def refund
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    return error_with_sale if purchase.nil?

    if purchase.refunded?
      purchase.errors.add(:base, "Purchase is already refunded.")
      return error_with_sale(purchase)
    end

    # The amount_cents param is denominated in the purchase's LISTED currency (the currency
    # the product is priced/displayed in, displayed_price_currency_type) — NOT the buyer's
    # presentment currency. Dividing by that currency's unit scaling factor turns it into a
    # major-unit amount that Purchase#refunding_amount_cents (app/models/purchase.rb) scales
    # back by the SAME listed currency and converts to canonical USD cents; for
    # buyer-presentment purchases the refund path then separately derives the amount to send
    # to Stripe in the buyer's currency via Purchase::PresentmentRefund
    # (app/modules/purchase/refundable.rb, refund_and_save!). Listed-currency input is
    # unambiguous today because the two denominations can never DIFFER while both being
    # non-USD: buyer presentment (the card path) only applies to USD-priced products, and
    # the local-method path that does charge in a non-USD currency (iDEAL/Bancontact in
    # euros, UPI in rupees — see Checkout::BuyerCurrencyEligibility) either charges a
    # product already priced in that same currency or converts from a USD-priced one. So
    # the caller always sees one non-USD amount at most, and the listed currency is the
    # only sensible reading of it. Once a product listed in one non-USD currency can be
    # charged in a DIFFERENT non-USD presentment currency (see gumroad-private#1321), a
    # caller reading the buyer's receipt could reasonably send the presentment amount
    # instead, and this line would silently misinterpret it — the API contract ("amount is
    # in the listed currency") would need to be made explicit or the param re-specified.
    amount = params[:amount_cents].to_i / unit_scaling_factor(purchase.displayed_price_currency_type).to_f if params[:amount_cents].present?

    if purchase.refund!(refunding_user_id: current_resource_owner.id, amount:)
      success_with_sale(purchase.as_json(version: 2, include_buyer_presentment: true))
    else
      error_with_sale(purchase)
    end
  end

  def resend_receipt
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    return error_with_sale if purchase.nil?

    purchase.resend_receipt
    render_response(true)
  end

  def revoke_access
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    return error_with_sale if purchase.nil?

    unless sale_purchase_policy(purchase).revoke_access?
      purchase.errors.add(:base, "Access cannot be revoked for this sale.")
      return error_with_sale(purchase)
    end

    purchase.update!(is_access_revoked: true)
    success_with_sale(purchase.as_json(version: 2, include_buyer_presentment: true))
  end

  def undo_revoke_access
    purchase = current_resource_owner.sales.find_by_external_id(params[:id])
    return error_with_sale if purchase.nil?

    unless sale_purchase_policy(purchase).undo_revoke_access?
      purchase.errors.add(:base, "Access is not revoked for this sale.")
      return error_with_sale(purchase)
    end

    purchase.update!(is_access_revoked: false)
    success_with_sale(purchase.as_json(version: 2, include_buyer_presentment: true))
  end

  private
    def success_with_sale(sale = nil)
      success_with_object(:sale, sale)
    end

    def sale_purchase_policy(purchase)
      Audience::PurchasePolicy.new(
        SellerContext.new(user: current_resource_owner, seller: current_resource_owner),
        purchase
      )
    end

    def error_with_sale(sale = nil)
      error_with_object(:sale, sale)
    end

    def filter_sales(start_date:, end_date:, email:, product_id:, purchase_id:, name: nil, license_key: nil, root_scope: Purchase)
      sales = root_scope
      sales = sales.where("created_at >= ?", start_date) if start_date
      sales = sales.where("created_at < ?", end_date) if end_date
      sales = sales.where(email:) if email.present?
      sales = sales.where(link_id: product_id) if product_id.present?
      sales = sales.where(id: purchase_id) if purchase_id.present?
      sales = sales.where("full_name LIKE ?", "%#{Purchase.sanitize_sql_like(name)}%") if name.present?
      sales = sales.where(id: sale_ids_for_license_key(license_key)) if license_key.present?
      sales.order(created_at: :desc, id: :desc)
    end

    # Licenses for gifted products live on the giftee purchase, which
    # for_sales_api then drops. Prefer the gift's payer leg so a license_key
    # lookup returns the same sale the unfiltered Sales API already lists.
    def sale_ids_for_license_key(license_key)
      holder_ids = License.where(serial: license_key.upcase).select(:purchase_id)
      Purchase.unscoped
        .where(id: holder_ids)
        .joins("LEFT JOIN gifts ON gifts.giftee_purchase_id = purchases.id")
        .select("COALESCE(gifts.gifter_purchase_id, purchases.id)")
    end

    def export_filters
      filters = {}
      if params[:from].present?
        filters[:start_time] = parse_export_date_param(:from)
        return filters if performed?
      end
      if params[:to].present?
        filters[:end_time] = parse_export_date_param(:to)
        return filters if performed?
      end

      if params[:product_id].present?
        product = current_resource_owner.links.find_by_external_id(params[:product_id])
        return error_400("Invalid product ID.") if product.nil?

        filters[:product_ids] = [product.external_id]
      end

      filters
    end

    def parse_export_date_param(param)
      Date.strptime(params[param], "%Y-%m-%d")
      params[param]
    rescue ArgumentError
      error_400("Invalid date format provided in field '#{param}'. Dates must be in the format YYYY-MM-DD.")
    end

    def sales_summary_params
      group_by = params[:group_by].presence
      if group_by.present? && Api::V2::SalesSummary::VALID_GROUPS.exclude?(group_by)
        return error_400("Invalid group_by. Valid values are: #{Api::V2::SalesSummary::VALID_GROUPS.join(', ')}.")
      end

      from = parse_summary_date_param(:from) if params[:from].present?
      return if performed?

      to = params[:to].present? ? parse_summary_date_param(:to) : ActiveSupport::TimeZone[current_resource_owner.timezone].today
      return if performed?

      from ||= to - 29

      return error_400("'from' must be on or before 'to'.") if from > to
      # Hourly grouping produces 24 buckets per day, so it only allows short ranges.
      if group_by == "hour" && (to - from).to_i > CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS
        return error_400("Date range cannot exceed #{CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS} days when grouping by hour.")
      end

      { from:, to:, group_by: }
    end

    def parse_summary_date_param(param)
      Date.strptime(params[param], "%Y-%m-%d")
    rescue ArgumentError
      error_400("Invalid date format provided in field '#{param}'. Dates must be in the format YYYY-MM-DD.")
    end

    def set_page # DEPRECATED
      page = params[:page]
      @page = page.is_a?(Integer) || page.is_a?(String) ? page.to_i : 1
      error_400("Invalid page number. Page numbers start at 1.") unless @page > 0
    end
end
