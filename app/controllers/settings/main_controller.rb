# frozen_string_literal: true

class Settings::MainController < Sellers::BaseController
  include ActiveSupport::NumberHelper

  before_action :authorize

  def show
    @title = "Settings"
    @react_component_props = SettingsPresenter.new(pundit_user:).main_props
  end

  def update
    begin
      current_seller.with_lock { current_seller.update(user_params.except(:seller_refund_policy)) }
    rescue StandardError => e
      Bugsnag.notify(e)
      return render json: { success: false, error_message: "Something broke. We're looking into what happened. Sorry about this!" }
    end

    if params[:user][:email] == current_seller.email
      current_seller.unconfirmed_email = nil
    end

    if current_seller.account_level_refund_policy_enabled?
      current_seller.refund_policy.update!(
        max_refund_period_in_days: seller_refund_policy_params[:max_refund_period_in_days],
        fine_print: seller_refund_policy_params[:fine_print],
      )
    end

    if current_seller.save
      current_seller.update_purchasing_power_parity_excluded_products!(params[:user][:purchasing_power_parity_excluded_product_ids])

      render json: { success: true }
    else
      render json: { success: false, error_message: current_seller.errors.full_messages.to_sentence }
    end
  end

  def resend_confirmation_email
    if current_seller.unconfirmed_email.present? || !current_seller.confirmed?
      current_seller.send_confirmation_instructions
      return render json: { success: true }
    end
    render json: { success: false }
  end

  private
    def user_params
      permitted_params = [
        :email,
        :enable_payment_email,
        :enable_payment_push_notification,
        :enable_recurring_subscription_charge_email,
        :enable_recurring_subscription_charge_push_notification,
        :enable_free_downloads_email,
        :enable_free_downloads_push_notification,
        :announcement_notification_enabled,
        :disable_comments_email,
        :disable_reviews_email,
        :support_email,
        :locale,
        :timezone,
        :currency_type,
        :purchasing_power_parity_enabled,
        :purchasing_power_parity_limit,
        :purchasing_power_parity_payment_verification_disabled,
        :show_nsfw_products,
        { seller_refund_policy: [:max_refund_period_in_days, :fine_print] }
      ]

      params.require(:user).permit(permitted_params)
    end

    def seller_refund_policy_params
      params[:user][:seller_refund_policy]&.permit(:max_refund_period_in_days, :fine_print)
    end

    def fetch_discover_sales(seller)
      PurchaseSearchService.search(
        seller:,
        price_greater_than: 0,
        recommended: true,
        state: "successful",
        exclude_bundle_product_purchases: true,
        aggs: { price_cents_total: { sum: { field: "price_cents" } } }
      ).aggregations["price_cents_total"]["value"]
    end

    def authorize
      super([:settings, :main, current_seller])
    end
end
