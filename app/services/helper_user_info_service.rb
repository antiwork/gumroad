# frozen_string_literal: true

class HelperUserInfoService
  include Rails.application.routes.url_helpers

  def initialize(email:, recent_purchase_period: 1.year)
    @email = email
    @recent_purchase_period = recent_purchase_period
  end

  STRUCTURED_COMMENTS_LIMIT = 50
  FALLBACK_AUTHOR_NAME = "System"

  def self.serialize_comment(comment)
    {
      id: comment.external_id,
      author_name: comment.author_name.presence || comment.author&.name || FALLBACK_AUTHOR_NAME,
      content: comment.content,
      comment_type: comment.comment_type,
      created_at: comment.created_at.iso8601
    }
  end

  def customer_info
    {
      **user_details,
      comments: structured_comments,
      can_add_comment: primary_email_user.present?,
      metadata: {
        **user_metadata,
        **sales_info,
        **recent_purchase_info,
      }
    }
  end

  private
    def primary_email_user
      return @_primary_email_user if defined?(@_primary_email_user)
      @_primary_email_user = (user if user&.email == @email && !user&.deleted?)
    end

    def structured_comments
      return [] unless primary_email_user
      primary_email_user.comments.includes(:author).order(created_at: :desc).limit(STRUCTURED_COMMENTS_LIMIT).map do |comment|
        self.class.serialize_comment(comment)
      end
    end

    def user_details
      return {} unless user

      details = {
        name: user.name,
        value: [
          user.sales_cents_total,
          purchases_cents_total(after: 90.days.ago)
        ].max,
        actions: {
          "Admin (user)" => admin_user_url(user, host: UrlService.domain_with_protocol),
          "Admin (purchases)" => admin_search_purchases_url(query: user.email, host: UrlService.domain_with_protocol),
          "Impersonate" => admin_impersonate_helper_action_url(user_external_id: user.external_id, host: UrlService.domain_with_protocol)
        }
      }

      if user.merchant_accounts.alive.stripe.first&.charge_processor_merchant_id
        details[:actions]["View Stripe account"] = admin_stripe_dashboard_helper_action_url(user_external_id: user.external_id, host: UrlService.domain_with_protocol)
      end

      details
    end

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

    def user_metadata
      return {} unless user
      {
        "User ID" => user.id,
        "Account Created" => user.created_at.to_fs(:formatted_date_full_month),
        "Account Status" => user.suspended? ? "Suspended" : "Active",
        "Country" => user.country,
      }.compact_blank
    end

    def recent_purchase_info
      recent_purchase = find_recent_purchase
      return unless recent_purchase

      product = recent_purchase.link
      purchase_info = if recent_purchase.failed?
        failed_purchase_info(recent_purchase, product)
      else
        successful_purchase_info(recent_purchase, product)
      end

      { "Most Recent Purchase" => { **purchase_info, **refund_policy_info(recent_purchase) } }
    end

    def find_recent_purchase
      if user
        user.purchases.created_after(@recent_purchase_period.ago).where.not(id: user.purchases.test_successful).last
      else
        Purchase.created_after(@recent_purchase_period.ago).where(email: @email).last
      end
    end

    def failed_purchase_info(purchase, product)
      {
        "Status" => "Failed",
        "Error" => purchase.formatted_error_code,
        "Product" => product.name,
        "Price" => purchase.formatted_display_price,
        "Date" => purchase.created_at.to_fs(:formatted_date_full_month),
      }
    end

    def successful_purchase_info(purchase, product)
      {
        "Status" => "Successful",
        "Product" => product.name,
        "Price" => purchase.formatted_display_price,
        "Date" => purchase.created_at.to_fs(:formatted_date_full_month),
        "Product URL" => product.long_url,
        "Creator Support Email" => purchase.seller.support_email || purchase.seller.form_email,
        "Creator Email" => purchase.seller_email,
        "Receipt URL" => receipt_purchase_url(purchase.external_id, host: DOMAIN, email: purchase.email),
        "License Key" => purchase.license_key,
      }
    end

    def refund_policy_info(purchase)
      return unless purchase.purchase_refund_policy

      policy = purchase.purchase_refund_policy
      { "Refund Policy" => policy.fine_print || policy.title }
    end

    def sales_info
      return {} unless user
      { "Total Earnings Since Joining" => Money.from_cents(user.sales_cents_total).format }
    end
end
