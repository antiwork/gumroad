# frozen_string_literal: true

class CustomersController < Sellers::BaseController
  include CurrencyHelper

  before_action :authorize
  before_action :set_body_id_as_app
  before_action :set_on_page_type

  CUSTOMERS_PER_PAGE = 20

  def index
    product = Link.fetch(params[:link_id]) if params[:link_id].present?
    sales = fetch_sales(products: [product].compact)
    @customers_presenter = CustomersPresenter.new(
      pundit_user:,
      product:,
      customers: load_sales(sales),
      pagination: { page: 1, pages: (sales.results.total / CUSTOMERS_PER_PAGE.to_f).ceil, next: nil },
      count: sales.results.total
    )
    create_user_event("customers_view")
  end

  def paged
    params[:page] = params[:page].to_i - 1
    sales = fetch_sales(
      query: params[:query],
      sort: params[:sort] ? { params[:sort][:key] => { order: params[:sort][:direction] } } : nil,
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
    )
    customers_presenter = CustomersPresenter.new(
      pundit_user:,
      customers: load_sales(sales),
      pagination: { page: params[:page].to_i + 1, pages: (sales.results.total / CUSTOMERS_PER_PAGE.to_f).ceil, next: nil },
      count: sales.results.total
    )

    render json: customers_presenter.customers_props
  end

  def customer_charges
    purchase = Purchase.where(email: params[:purchase_email].to_s).find_by_external_id!(params[:purchase_id])

    if purchase.is_original_subscription_purchase?
      return render json: purchase.subscription.purchases.successful.map { CustomerPresenter.new(purchase: _1).charge }
    elsif purchase.is_commission_deposit_purchase?
      return render json: [purchase, purchase.commission.completion_purchase].compact.map { CustomerPresenter.new(purchase: _1).charge }
    end

    render json: []
  end

  def customer_emails
    original_purchase = current_seller.sales.find_by_external_id!(params[:purchase_id]) if params[:purchase_id].present?

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

    posts = original_purchase.installments.alive.where(seller_id: original_purchase.seller_id).map do |post|
      email_info = CreatorContactingCustomersEmailInfo.where(purchase: original_purchase, installment: post).last
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
    emails = receipts + emails unless original_purchase.is_bundle_product_purchase?

    render json: emails
  end

  def missed_posts
    purchase = Purchase.where(email: params[:purchase_email].to_s).find_by_external_id!(params[:purchase_id])

    render json: CustomerPresenter.new(purchase:).missed_posts
  end

  def product_purchases
    purchase = current_seller.sales.find_by_external_id!(params[:purchase_id]) if params[:purchase_id].present?

    render json: purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) }
  end

  private
    def fetch_sales(query: nil, sort: nil, products: nil, variants: nil, excluded_products: nil, excluded_variants: nil, minimum_amount_cents: nil, maximum_amount_cents: nil, created_after: nil, created_before: nil, country: nil, active_customers_only: false)
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
        from: params[:page].to_i * CUSTOMERS_PER_PAGE,
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
        search_options[:exclude_refunded_except_subscriptions] = true
        search_options[:exclude_unreversed_chargedback] = true
      end

      search_options[:price_greater_than] = get_usd_cents(current_seller.currency_type, minimum_amount_cents) if minimum_amount_cents.present?
      search_options[:price_less_than] = get_usd_cents(current_seller.currency_type, maximum_amount_cents) if maximum_amount_cents.present?

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
          :purchase_offer_code_discount,
          :tip,
          :upsell_purchase,
          :variant_attributes,
          product_review: [:response, { alive_videos: [:video_file] }],
          utm_link: [target_resource: [:seller, :user]]
        )
        .load
    end

    def set_title
      @title = "Sales"
    end

    def set_on_page_type
      @on_customers_page = true
    end

    def authorize
      super([:audience, Purchase], :index?)
    end
end
