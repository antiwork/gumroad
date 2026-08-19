# frozen_string_literal: true

# The admin web UI was removed; this controller keeps the team-member
# Stripe dashboard redirect that the internal admin API still links to.
class Admin::BaseController < ApplicationController
  before_action :require_admin!

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
        redirect_to root_path
      end
    else
      flash[:alert] = "User not found"
      redirect_to root_path
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
