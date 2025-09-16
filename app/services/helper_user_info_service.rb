# frozen_string_literal: true

class HelperUserInfoService
  include Rails.application.routes.url_helpers

  def initialize(email:, recent_purchase_period: 1.year)
    @email = email
    @recent_purchase_period = recent_purchase_period
  end

  def customer_info
    {
      **user_details,
      metadata: {
        **user_metadata,
        **seller_comments,
        **sales_info,
        **recent_purchase_info,
      }
    }
  end

  private
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
          "Impersonate" => admin_impersonate_helper_action_url(user_id: user.external_id, host: UrlService.domain_with_protocol)
        }
      }

      if user.merchant_accounts.alive.stripe.first&.charge_processor_merchant_id
        details[:actions]["View Stripe account"] = admin_stripe_dashboard_helper_action_url(user_id: user.external_id, host: UrlService.domain_with_protocol)
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

    def seller_comments
      return {} unless user
      comments = user.comments.order(:created_at)

      formatted_comments = comments.map do |comment|
        case comment.comment_type
        when Comment::COMMENT_TYPE_PAYOUT_NOTE
          "Payout Note: #{comment.content}" if comment.author_id == GUMROAD_ADMIN_ID
        when Comment::COMMENT_TYPE_SUSPENSION_NOTE
          "Suspension Note: #{comment.content}" if user.suspended?
        when *Comment::RISK_STATE_COMMENT_TYPES
          "Risk Note: #{comment.content}"
        else
          "Comment: #{comment.content}"
        end
      end

      { "Comments" => formatted_comments } if formatted_comments.present?
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
