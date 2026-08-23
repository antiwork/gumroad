# frozen_string_literal: true

class CustomersController < Sellers::BaseController
  include CurrencyHelper

  rescue_from Faraday::TimeoutError, with: :handle_search_timeout
  rescue_from Elasticsearch::Transport::Transport::Errors::BadRequest, with: :handle_search_error


  before_action :authorize
  before_action :set_on_page_type

  CUSTOMERS_PER_PAGE = 20
  # Elasticsearch's index.max_result_window caps `from + size` at 10_000, so a seller
  # with more than 10k sales cannot page past (10_000 / CUSTOMERS_PER_PAGE) without the
  # index rejecting the request. Cap both the requested offset and the advertised page
  # count to keep the Sales list's last page reachable instead of a 500.
  MAX_RESULT_WINDOW = 10_000

  layout "inertia", only: [:index, :show]

  def index
    product = Link.fetch(params[:link_id]) if params[:link_id].present?
    sales = fetch_sales(products: [product].compact)
    customers_presenter = CustomersPresenter.new(
      pundit_user:,
      product:,
      customers: load_sales(sales),
      pagination: { page: 1, pages: total_pages(sales.results.total), next: nil },
      count: sales.results.total
    )
    create_user_event("customers_view")

    render inertia: "Customers/Index",
           props: { customers_presenter: customers_presenter.customers_props }
  end

  def show
    purchase = current_seller.sales.find_by_external_id!(params[:purchase_id])
    presenter = CustomerPresenter.new(purchase:)
    customer_data = presenter.customer(pundit_user:)
    user_presenter = UserPresenter.new(user: current_seller)

    render inertia: "Customers/Show",
           props: {
             customer: customer_data,
             countries: Compliance::Countries.for_select.map(&:last),
             can_ping: current_seller.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME).size > 0,
             can_email: user_presenter.audience_types.include?(:customers) && policy(Installment).create?,
             show_refund_fee_notice: current_seller.show_refund_fee_notice?,
             emails: build_customer_emails(purchase),
             missed_posts: InertiaRails.defer { presenter.missed_posts },
             charges: build_charges(purchase),
             product_purchases: purchase.is_bundle_purchase ? purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) } : [],
           }
  end

  # Text fields aren't sortable in ES; product_name sorts on its keyword subfield.
  SORT_KEY_TO_SEARCH_FIELD = {
    "created_at" => "created_at",
    "price_cents" => "price_cents",
    "product_name" => "product_name.raw",
  }.freeze

  def paged
    params[:page] = params[:page].to_i - 1
    sort_field = SORT_KEY_TO_SEARCH_FIELD[params.dig(:sort, :key)]
    sort_direction = params.dig(:sort, :direction) == "asc" ? "asc" : "desc"
    sales = fetch_sales(
      query: params[:query],
      sort: sort_field ? { sort_field => { order: sort_direction } } : nil,
      products: Link.by_external_ids(params[:products]),
      variants: BaseVariant.by_external_ids(params[:variants]),
      excluded_products: Link.by_external_ids(params[:excluded_products]),
      excluded_variants: BaseVariant.by_external_ids(params[:excluded_variants]),
      minimum_amount_cents: params[:minimum_amount_cents],
      maximum_amount_cents: params[:maximum_amount_cents],
      created_after: params[:created_after],
      created_before: params[:created_before],
      country: params[:country],
      active_customers_only: ActiveModel::Type::Boolean.new.cast(params[:active_customers_only]),
      minimum_license_uses: Feature.active?(:license_uses_sales_filter, current_seller) ? params[:minimum_license_uses] : nil,
    )
    customers_presenter = CustomersPresenter.new(
      pundit_user:,
      customers: load_sales(sales),
      pagination: { page: params[:page].to_i + 1, pages: total_pages(sales.results.total), next: nil },
      count: sales.results.total
    )

    render json: customers_presenter.customers_props
  end

  def customer_charges
    purchase = Purchase.where(email: params[:purchase_email].to_s).find_by_external_id!(params[:purchase_id])
    render json: build_charges(purchase)
  end

  def customer_emails
    purchase = current_seller.sales.find_by_external_id!(params[:purchase_id]) if params[:purchase_id].present?
    render json: build_customer_emails(purchase)
  end

  def missed_posts
    purchase = Purchase.where(email: params[:purchase_email].to_s).find_by_external_id!(params[:purchase_id])

    render json: CustomerPresenter.new(purchase:).missed_posts
  end

  def product_purchases
    purchase = current_seller.sales.find_by_external_id!(params[:purchase_id]) if params[:purchase_id].present?

    render json: purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) }
  end

  def handle_search_timeout
    if action_name == "paged"
      render json: { success: false, error: "request timed out" }, status: :gateway_timeout
    else
      redirect_back fallback_location: root_path, warning: "Request timed out. Please try again.", status: :see_other
    end
  end

  def handle_search_error
    if action_name == "paged"
      render json: { success: false, error: "search failed" }, status: :bad_request
    else
      redirect_back fallback_location: root_path, warning: "Request failed. Please try again.", status: :see_other
    end
  end

  private
    # `from` is 0-indexed; page 500 (1-indexed) is the last legal ES window (9980). Clamp
    # requests past it to that window so a deep page renders the last page rather than
    # an ES "Result window is too large" rejection.
    def page_offset
      params[:page].to_i.clamp(0, MAX_RESULT_WINDOW / CUSTOMERS_PER_PAGE - 1) * CUSTOMERS_PER_PAGE
    end

    def total_pages(total)
      [(total / CUSTOMERS_PER_PAGE.to_f).ceil, MAX_RESULT_WINDOW / CUSTOMERS_PER_PAGE].min
    end

    def fetch_sales(query: nil, sort: nil, products: nil, variants: nil, excluded_products: nil, excluded_variants: nil, minimum_amount_cents: nil, maximum_amount_cents: nil, created_after: nil, created_before: nil, country: nil, active_customers_only: false, minimum_license_uses: nil)
      search_options = {
        seller: current_seller,
        country: Compliance::Countries.historical_names(country || params[:bought_from]).presence,
        state: Purchase::NON_GIFT_SUCCESS_STATES,
        any_products_or_variants: {},
        exclude_purchasers_of_product: excluded_products,
        exclude_purchasers_of_variant: excluded_variants,
        exclude_non_original_subscription_purchases: true,
        exclude_giftees: true,
        exclude_bundle_product_purchases: true,
        exclude_commission_completion_purchases: true,
        from: page_offset,
        size: CUSTOMERS_PER_PAGE,
        sort: [{ created_at: { order: :desc } }, { id: { order: :desc } }],
        track_total_hits: true,
        seller_query: query || params[:query],
      }
      search_options[:sort].unshift(sort) if sort.present?
      search_options[:any_products_or_variants][:products] = products if products.present?
      search_options[:any_products_or_variants][:variants] = variants if variants.present?

      if active_customers_only
        search_options[:exclude_deactivated_subscriptions] = true
        search_options[:exclude_cancelled_or_pending_cancellation_subscriptions] = true
        search_options[:exclude_refunded_except_subscriptions] = true
        search_options[:exclude_unreversed_chargedback] = true
      end

      search_options[:price_greater_than] = get_usd_cents(current_seller.currency_type, minimum_amount_cents) if minimum_amount_cents.present?
      search_options[:price_less_than] = get_usd_cents(current_seller.currency_type, maximum_amount_cents) if maximum_amount_cents.present?

      search_options[:license_uses_greater_than_or_equal_to] = minimum_license_uses.to_i if minimum_license_uses.present?

      if created_after || created_before
        timezone = ActiveSupport::TimeZone[current_seller.timezone]
        search_options[:created_on_or_after] = timezone.parse(created_after) if created_after
        search_options[:created_before] = timezone.parse(created_before).tomorrow if created_before
        if search_options[:created_on_or_after] && search_options[:created_before] && search_options[:created_on_or_after] > search_options[:created_before]
          search_options.except!(:created_before, :created_on_or_after)
        end
      end

      PurchaseSearchService.search(search_options)
    end

    def load_sales(sales)
      sales.records
        .includes(
          :call,
          :license,
          :merchant_account,
          :offer_code,
          :preorder,
          :price,
          :purchaser,
          # Lets Purchase#amount_refunded_cents take its in-memory Refund#effective?
          # branch. Unpreloaded it runs a per-row SUM for cents_refundable.
          :refunds,
          :seller,
          :shipment,
          :tip,
          :url_redirect,
          :variant_attributes,
          affiliate: :affiliate_user,
          commission_as_deposit: [:completion_purchase, { files_attachments: :blob }],
          link: :alive_variants,
          product_review: [:response, { alive_videos: [:video_file] }],
          purchase_custom_fields: { files_attachments: :blob },
          purchase_offer_code_discount: :offer_code,
          # original_product_review goes through Subscription#true_original_purchase (a different
          # Purchase), so the top-level product_review preload never applies to memberships.
          # :original_purchase is a separate cache; current_subscription_price_cents reads it.
          subscription: [
            :original_purchase,
            {
              last_payment_option: [:price, :installment_plan, :installment_plan_snapshot],
              true_original_purchase: { product_review: [:response, { alive_videos: [:video_file] }] }
            }
          ],
          upsell_purchase: :upsell,
          utm_link: [target_resource: [:seller, :user]]
        )
        .in_order_of(:id, sales.records.ids)
        .load
    end

    def build_charges(purchase)
      if purchase.is_original_subscription_purchase?
        purchase.subscription.purchases.successful.map { CustomerPresenter.new(purchase: _1).charge }
      elsif purchase.is_commission_deposit_purchase?
        [purchase, purchase.commission.completion_purchase].compact.map { CustomerPresenter.new(purchase: _1).charge }
      else
        []
      end
    end

    def build_customer_emails(original_purchase)
      all_purchases = if original_purchase.subscription.present?
        original_purchase.subscription.purchases.all_success_states_except_preorder_auth_and_gift.preload(:receipt_email_info_from_purchase)
      else
        [original_purchase]
      end

      receipts = all_purchases.map do |purchase|
        receipt_email_info = purchase.receipt_email_info
        {
          type: "receipt",
          name: receipt_email_info&.email_name&.humanize || "Receipt",
          id: purchase.external_id,
          state: receipt_email_info&.state&.humanize || "Delivered",
          state_at: receipt_email_info.present? ? receipt_email_info.most_recent_state_at.in_time_zone(current_seller.timezone) : purchase.created_at.in_time_zone(current_seller.timezone),
          url: receipt_purchase_url(purchase.external_id, email: purchase.email),
          date: purchase.created_at
        }
      end

      installments = original_purchase.installments.alive.where(seller_id: original_purchase.seller_id).to_a
      email_infos_by_installment = CreatorContactingCustomersEmailInfo
        .where(purchase: original_purchase, installment_id: installments.map(&:id))
        .order(:id)
        .group_by(&:installment_id)
        .transform_values(&:last)

      posts = installments.map do |post|
        email_info = email_infos_by_installment[post.id]
        {
          type: "post",
          name: post.name,
          id: post.external_id,
          state: email_info.state.humanize,
          state_at: email_info.most_recent_state_at.in_time_zone(current_seller.timezone),
          date: post.published_at
        }
      end

      unpublished_posts = posts.select { |post| post[:date].nil? }
      published_posts = posts - unpublished_posts
      emails = published_posts
      emails = emails.sort_by { |e| -e[:date].to_i } + unpublished_posts
      emails = receipts + emails if !original_purchase.is_bundle_product_purchase?

      emails
    end

    def set_default_page_title
      set_meta_tag(title: "Sales")
    end

    def set_on_page_type
      @on_customers_page = true
    end

    def authorize
      super([:audience, Purchase], :index?)
    end
end
