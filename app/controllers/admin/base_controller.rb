# frozen_string_literal: true

class Admin::BaseController < ApplicationController
  include ActionView::Helpers::DateHelper, ActionView::Helpers::NumberHelper, AdminActionTracker, Impersonate

  layout "admin"

  inertia_share do
    {
      card_types: CreditCardUtility.card_types_for_react
    }
  end

  before_action :require_admin!
  before_action :hide_layouts

  before_action do
    @body_id = "admin"
    @title = "Admin"
  end

  def index
    @title = "Admin"
    render inertia: "Admin/Base/Index"
  end

  def impersonate
    user = find_user(params[:user_identifier])

    if user
      impersonate_user(user)
      redirect_to dashboard_path
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

  protected
    # Override render to allow serving Inertia-admin pages inside the legacy "admin_old" layout, for transitional/testing purposes.
    #
    # Normal usage:
    #   - For standard HTML requests: use the default render behavior.
    #   - For render(partial: ...): use the default render (do NOT use the admin_old layout).
    #   - For requests with inertia: By default, use the normal layout.
    #   - If params[:admin_old] is set and inertia is present: Render the React page server-side
    #     but in the admin_old layout, and map each React prop to an instance variable
    #     for legacy view compatibility. It looks for a template file based on the inertia name,
    #     lowercased and suffixed with '_old' (e.g., Admin/Base/Index => admin/base/index_old).
    def render(*args, **kwargs)
      Rails.logger.warn("Warning: render(*args, **kwargs) is being overridden in Admin::BaseController")
      Rails.logger.warn("args: #{args.inspect}")
      Rails.logger.warn("kwargs: #{kwargs.inspect}")
      Rails.logger.warn("Make sure to remove this override when we are done migrating to Inertia.")

      return super(*args, **kwargs) unless request.format.html?
      return super(*args, **kwargs) if kwargs.key?(:partial)
      return super(*args, layout: "admin_old", **kwargs) unless kwargs.key?(:inertia)
      return super(*args, **kwargs) unless params[:admin_old]

      kwargs[:props] ||= {}
      kwargs[:props].each_key do |key|
        instance_variable_set("@#{key}", kwargs[:props][key])
      end

      render template: kwargs[:inertia].underscore, layout: "admin_old"
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
