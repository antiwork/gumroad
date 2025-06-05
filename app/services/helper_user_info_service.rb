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
      add_payout_notes
      add_risk_notes
      add_suspension_notes
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
      @info << "Account Status: #{user.suspended? ? 'Suspended' : 'Active'}"
    end

    def add_payout_notes
      payout_note = user.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last
      @info << "Payout Note: #{payout_note.content}" if payout_note
    end

    def add_risk_notes
      risk_notes = Comment::RISK_STATE_COMMENT_TYPES.map do |comment_type|
        user.comments.where(comment_type:).last
      end.compact.sort_by(&:created_at).pluck(:content)

      @info.concat(risk_notes.map { |note| "Risk Note: #{note}" })
    end

    def add_suspension_notes
      return unless user.suspended?

      suspension_note = user.comments.where(comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE).last
      @info << "Suspension Note: #{suspension_note.content}" if suspension_note
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
