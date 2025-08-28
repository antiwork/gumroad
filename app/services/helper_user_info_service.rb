# frozen_string_literal: true

class HelperUserInfoService
  include Rails.application.routes.url_helpers

  def initialize(email:, recent_purchase_period: 1.year)
    @email = email
    @recent_purchase_period = recent_purchase_period
  end

  def user_info
    @info = []

    if user
      add_user_info
      add_seller_comments
      add_sales_info
    end

    add_recent_purchase_info

    {
      prompt: @info.join("\n"),
      metadata: metadata
    }
  end

  def metadata
    return {} unless user

    metadata = {
      name: user.name,
      email: user.email,
      value: [
        user.sales_cents_total,
        purchases_cents_total(after: 90.days.ago)
      ].max,
      links: {
        "Admin (user)": admin_user_url(user, host: UrlService.domain_with_protocol),
        "Admin (purchases)": admin_search_purchases_url(query: user.email, host: UrlService.domain_with_protocol),
        "Impersonate": admin_impersonate_helper_action_url(user_id: user.external_id, host: UrlService.domain_with_protocol)
      }
    }

    if user.merchant_accounts.alive.stripe.first&.charge_processor_merchant_id
      metadata[:links]["View Stripe account"] = admin_stripe_dashboard_helper_action_url(user_id: user.external_id, host: UrlService.domain_with_protocol)
    end

    metadata
  end

  private
    def purchases_cents_total(after: nil)
      search_params = {
        purchaser: user,
        state: "successful",
        exclude_unreversed_chargedback: true,
        exclude_refunded: true,
        size: 0,
        aggs: {
          price_cents_total: { sum: { field: "price_cents" } },
          amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } }
        }
      }

      search_params[:created_after] = after if after

      result = PurchaseSearchService.search(search_params)
      total = result.aggregations.price_cents_total.value - result.aggregations.amount_refunded_cents_total.value
      total.to_i
    end

    def user
      @_user ||= User.find_by(email: @email) || User.find_by(support_email: @email)
    end

    def add_user_info
      @info << "User ID: #{user.id}"
      @info << "User Name: #{user.name}"
      @info << "User Email: #{user.email}"
      @info << "Account Created: #{user.created_at.to_fs(:formatted_date_full_month)}"
      @info << "Account Status: #{user.suspended? ? 'Suspended' : 'Active'}"
      @info << "Country: #{user.country}" if user.country.present?
    end

    def add_seller_comments
      comments = user.comments.order(:created_at)

      comments.each do |comment|
        case comment.comment_type
        when Comment::COMMENT_TYPE_PAYOUT_NOTE
          @info << "Payout Note: #{comment.content}" if comment.author_id == GUMROAD_ADMIN_ID
        when Comment::COMMENT_TYPE_SUSPENSION_NOTE
          @info << "Suspension Note: #{comment.content}" if user.suspended?
        when *Comment::RISK_STATE_COMMENT_TYPES
          @info << "Risk Note: #{comment.content}"
        else
          @info << "Comment: #{comment.content}"
        end
      end
    end

    def add_recent_purchase_info
      recent_purchase = find_recent_purchase
      return unless recent_purchase

      product = recent_purchase.link
      if recent_purchase.failed?
        add_failed_purchase_info(recent_purchase, product)
      else
        add_successful_purchase_info(recent_purchase, product)
      end

      add_refund_policy_info(recent_purchase)
    end

    def find_recent_purchase
      if user
        user.purchases.created_after(@recent_purchase_period.ago).where.not(id: user.purchases.test_successful).last
      else
        Purchase.created_after(@recent_purchase_period.ago).where(email: @email).last
      end
    end

    def add_failed_purchase_info(purchase, product)
      @info << "Failed Purchase Attempt: #{purchase.email} tried to buy #{product.name} for #{purchase.formatted_display_price} on #{purchase.created_at.to_fs(:formatted_date_full_month)}"
      @info << "Error: #{purchase.formatted_error_code}"
    end

    def add_successful_purchase_info(purchase, product)
      @info << "Successful Purchase: #{purchase.email} bought #{product.name} for #{purchase.formatted_display_price} on #{purchase.created_at.to_fs(:formatted_date_full_month)}"
      @info << "Product URL: #{product.long_url}"
      @info << "Creator Support Email: #{purchase.seller.support_email || purchase.seller.form_email}"
      @info << "Creator Email: #{purchase.seller_email}"
      @info << "Receipt URL: #{receipt_purchase_url(purchase.external_id, host: DOMAIN, email: purchase.email)}"
      @info << "License Key: #{purchase.license_key}" if purchase.license_key.present?
    end

    def add_refund_policy_info(purchase)
      return unless purchase.purchase_refund_policy

      policy = purchase.purchase_refund_policy
      @info << "Refund Policy: #{policy.fine_print || policy.title}"
    end

    def add_sales_info
      @info << "Total Earnings Since Joining: #{Money.from_cents(user.sales_cents_total).format}"
    end
end
