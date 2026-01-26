# frozen_string_literal: true

class Admin::BaseController < ApplicationController
  include ActionView::Helpers::DateHelper, ActionView::Helpers::NumberHelper, AdminActionTracker, Impersonate

  layout "admin"

  inertia_share do
    {
      card_types: CreditCardUtility.card_types_for_react,
      compliance: {
        reasons: Compliance::TOS_VIOLATION_REASONS,
        default_reason: Compliance::DEFAULT_TOS_VIOLATION_REASON
      }
    }
  end

  before_action :require_admin!
  before_action :hide_layouts

  before_action do
    @body_id = "admin"
    set_meta_tag(title: "Admin")
  end

  def index
    render inertia: "Admin/Base/Index"
  end

  def impersonate
    user = find_user(params[:user_identifier])

    if user
      impersonate_user(user)
      redirect_to products_path
    else
      flash[:alert] = "User not found"
      redirect_to admin_path
    end
  end

  def unimpersonate
    stop_impersonating_user

    render json: { redirect_to: admin_url }
  end

  def redirect_to_stripe_dashboard
    user = find_user(params[:user_identifier])

    if user
      merchant_account = user.merchant_accounts.alive.stripe.first

      if merchant_account&.charge_processor_merchant_id
        base_url = "https://dashboard.stripe.com"
        base_url += "/test" unless Rails.env.production?
        redirect_to "#{base_url}/connect/accounts/#{merchant_account.charge_processor_merchant_id}", allow_other_host: true
      else
        flash[:alert] = "Stripe account not found"
        redirect_to admin_path
      end
    else
      flash[:alert] = "User not found"
      redirect_to admin_path
    end
  end

  private
    def find_user(identifier)
      return nil if identifier.blank?

      User.find_by(external_id: identifier) ||
      User.find_by(email: identifier) ||
      User.find_by(username: identifier) ||
      MerchantAccount.stripe.find_by(charge_processor_merchant_id: identifier)&.user
    end

    def user_not_authorized(exception)
      message = "You are not allowed to perform this action."
      if request.format.json? || request.format.js?
        render json: { success: false, error: message }, status: :unauthorized
      else
        flash[:alert] = message
        redirect_to root_path
      end
    end

    def request_from_iffy?
      ActiveSupport::SecurityUtils.secure_compare(params[:auth_token].to_s, GlobalConfig.get("IFFY_TOKEN"))
    end

    def require_admin!
      if current_user.nil?
        return e404_json if xhr_or_json_request?
        return redirect_to login_path(next: request.path)
      end

      unless current_user.is_team_member?
        return e404_json if xhr_or_json_request?
        redirect_to root_path
      end
    end

    def xhr_or_json_request?
      request.xhr? || request.format.json?
    end
end
