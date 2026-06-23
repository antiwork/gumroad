# frozen_string_literal: true

class Api::Mobile::SalesController < Api::Mobile::BaseController
  include ProcessRefund
  include CdnUrlHelper

  SALES_PER_PAGE = 20

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :fetch_purchase, except: [:index, :blob_url, :refund]

  rescue_from Faraday::TimeoutError do
    render json: { success: false, message: "Sales request timed out" }, status: :gateway_timeout
  end

  rescue_from Rack::Timeout::RequestTimeoutException do
    render json: { success: false, message: "Sales request timed out" }, status: :gateway_timeout
  end

  def index
    page = [params[:page].to_i, 1].max
    search_result = PurchaseSearchService.search(
      seller: current_resource_owner,
      state: Purchase::NON_GIFT_SUCCESS_STATES,
      exclude_giftees: true,
      exclude_non_original_subscription_purchases: true,
      exclude_bundle_product_purchases: true,
      exclude_commission_completion_purchases: true,
      seller_query: params[:query].presence,
      from: (page - 1) * SALES_PER_PAGE,
      size: SALES_PER_PAGE,
      sort: [{ created_at: { order: :desc } }, { id: { order: :desc } }],
      track_total_hits: true,
    )
    sales_count = search_result.results.total
    pages = (sales_count / SALES_PER_PAGE.to_f).ceil
    purchases_json = search_result.records
      .includes(:seller, :purchaser, link: [:variant_categories_alive, { thumbnail: { file_attachment: :blob } }])
      .in_order_of(:id, search_result.records.ids)
      .as_json(creator_app_api: true)
    render json: {
      success: true,
      purchases: purchases_json,
      pagination: {
        count: sales_count,
        page:,
        pages:,
        next: page < pages ? page + 1 : nil,
      },
    }
  end

  def show
    render json: {
      success: true,
      purchase: @purchase.json_data_for_mobile({ include_sale_details: true }),
      customer: CustomerPresenter.new(purchase: @purchase).customer(pundit_user: seller_context),
      charges: build_charges(@purchase),
      emails: build_customer_emails(@purchase),
      product_purchases: @purchase.is_bundle_purchase ?
        @purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user: seller_context) } : [],
      can_ping: current_resource_owner.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME).size > 0,
    }
  end

  def update
    @purchase.email = params[:email].strip if params[:email].present?
    @purchase.full_name = params[:full_name] if params[:full_name].present?
    @purchase.street_address = params[:street_address] if params[:street_address].present?
    @purchase.city = params[:city] if params[:city].present?
    @purchase.state = params[:state] if params[:state].present?
    @purchase.zip_code = params[:zip_code] if params[:zip_code].present?
    if params[:country].present?
      country_name = Compliance::Countries.find_by_name(params[:country])&.common_name
      @purchase.country = country_name if country_name.present?
    end
    @purchase.quantity = params[:quantity] if @purchase.is_multiseat_license? && params[:quantity].to_i > 0

    if params[:giftee_email].present?
      gift = @purchase.gift
      return fetch_error("This sale is not a gift", status: :unprocessable_entity) if gift.nil?
      return fetch_error("This gift is missing a giftee purchase", status: :unprocessable_entity) if gift.giftee_purchase.nil?
    end

    giftee_purchase = nil
    ActiveRecord::Base.transaction do
      @purchase.save!

      if params[:email].present? && @purchase.is_bundle_purchase?
        @purchase.product_purchases.each { _1.update!(email: params[:email]) }
      end

      if params[:giftee_email].present? && @purchase.gift
        gift = @purchase.gift
        giftee_purchase = gift.giftee_purchase

        gift.giftee_email = params[:giftee_email]
        gift.save!

        giftee_purchase.email = params[:giftee_email]
        giftee_purchase.save!
      end
    end

    giftee_purchase&.resend_receipt

    render json: { success: @purchase.errors.empty? }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  def refund
    process_refund(seller: current_resource_owner, user: current_resource_owner,
                   purchase_external_id: params[:id], amount: params[:amount])
  end

  def resend_receipt
    return fetch_error("Could not find receipt") if receipt_orderable_missing?(@purchase)

    @purchase.resend_receipt
    render json: { success: true }
  end

  def change_can_contact
    @purchase.can_contact = ActiveModel::Type::Boolean.new.cast(params[:can_contact])
    @purchase.save!
    render json: { success: true }
  end

  def revoke_access
    return fetch_error("Not authorized", status: :unauthorized) unless purchase_policy.revoke_access?

    @purchase.update!(is_access_revoked: true)
    render json: { success: true }
  end

  def undo_revoke_access
    return fetch_error("Not authorized", status: :unauthorized) unless purchase_policy.undo_revoke_access?

    @purchase.update!(is_access_revoked: false)
    render json: { success: true }
  end

  def mark_as_shipped
    shipment = @purchase.shipment || Shipment.create(purchase: @purchase)
    unless shipment.persisted?
      return render json: { success: false, message: shipment.errors.full_messages.to_sentence.presence || "Could not mark as shipped" }, status: :unprocessable_entity
    end

    if params[:tracking_url].present?
      shipment.tracking_url = params[:tracking_url]
      shipment.save!
    end
    shipment.mark_shipped!
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  def resend_ping
    @purchase.send_notification_webhook_from_ui
    render json: { success: true }
  end

  def missed_posts
    render json: { success: true, missed_posts: CustomerPresenter.new(purchase: @purchase).missed_posts }
  end

  def product_purchases
    render json: {
      success: true,
      product_purchases: @purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user: seller_context) },
    }
  end

  def options
    return fetch_error("Could not find product") if @purchase.link.nil?

    render json: { success: true, options: @purchase.link.options }
  end

  def variant
    return fetch_error("Could not find product") if @purchase.link.nil?

    success = Purchase::VariantUpdaterService.new(
      purchase: @purchase,
      variant_id: params[:variant_id],
      quantity: params[:quantity].to_i,
    ).perform
    if success
      render json: { success: true }
    else
      render json: { success: false, message: "Variant not found" }, status: :not_found
    end
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: "Variant not found" }, status: :not_found
  end

  def send_post
    return fetch_error("You are not eligible to resend this email.", status: :unauthorized) unless current_resource_owner.eligible_to_send_emails?

    post = Installment.alive.where(seller_id: current_resource_owner.id).find_by_external_id(params[:post_id])
    return fetch_error("Could not find post") if post.nil?

    cache_key = "post_email:#{post.id}:#{@purchase.id}"
    sent = false
    Rails.cache.fetch(cache_key, expires_in: 8.hours) do
      sent = true
      CreatorContactingCustomersEmailInfo.where(purchase: @purchase, installment: post).destroy_all

      PostEmailApi.process(
        post:,
        recipients: [
          {
            email: @purchase.email,
            purchase: @purchase,
            url_redirect: @purchase.url_redirect,
            subscription: @purchase.subscription,
          }.compact_blank
        ])
      true
    end

    render json: { success: true, sent: }
  end

  def update_review_response
    review = @purchase.original_product_review
    return fetch_error("Could not find review") if review.nil?

    review_response = review.response || review.build_response
    if review_response.update(message: params[:message], user: current_resource_owner)
      render json: { success: true }
    else
      render json: { success: false, message: review_response.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def destroy_review_response
    review = @purchase.original_product_review
    return fetch_error("Could not find review response") if review&.response.nil?

    if review.response.destroy
      render json: { success: true }
    else
      render json: { success: false, message: review.response.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def blob_url
    blob = ActiveStorage::Blob.find_by_key(params[:key])
    return fetch_error("Could not find file") if blob.nil? || !seller_owns_blob?(blob)

    render json: { success: true, url: cdn_url_for(blob.url) }
  end

  private
    def fetch_purchase
      @purchase = current_resource_owner.sales.find_by_external_id(params[:id])
      fetch_error("Could not find purchase") if @purchase.nil?
    end

    def seller_owns_blob?(blob)
      seller_sales = current_resource_owner.sales.select(:id)

      commission_ids = blob.attachments.where(record_type: "Commission").select(:record_id)
      commissions = Commission.where(id: commission_ids)
      return true if commissions.where(deposit_purchase_id: seller_sales).or(commissions.where(completion_purchase_id: seller_sales)).exists?

      custom_field_ids = blob.attachments.where(record_type: "PurchaseCustomField").select(:record_id)
      PurchaseCustomField.where(id: custom_field_ids, purchase_id: seller_sales).exists?
    end

    def receipt_orderable_missing?(purchase)
      Charge::Chargeable.find_by_purchase_or_charge!(purchase:).orderable.email.blank?
    rescue ActiveRecord::RecordNotFound
      true
    end

    def seller_context
      SellerContext.new(user: current_resource_owner, seller: current_resource_owner)
    end

    def purchase_policy
      Audience::PurchasePolicy.new(seller_context, @purchase)
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
          state_at: receipt_email_info.present? ? receipt_email_info.most_recent_state_at.in_time_zone(current_resource_owner.timezone) : purchase.created_at.in_time_zone(current_resource_owner.timezone),
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

      posts = installments.filter_map do |post|
        email_info = email_infos_by_installment[post.id]
        next if email_info.nil?
        {
          type: "post",
          name: post.name,
          id: post.external_id,
          state: email_info.state.humanize,
          state_at: email_info.most_recent_state_at.in_time_zone(current_resource_owner.timezone),
          date: post.published_at
        }
      end

      unpublished_posts, published_posts = posts.partition { |post| post[:date].nil? }
      emails = published_posts.sort_by { |e| -e[:date].to_i } + unpublished_posts
      emails = receipts + emails unless original_purchase.is_bundle_product_purchase
      emails
    end
end
