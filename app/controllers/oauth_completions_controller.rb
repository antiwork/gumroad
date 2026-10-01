# frozen_string_literal: true

class OauthCompletionsController < ApplicationController
  include AuditsPayoutSettingsChanges

  UNSETTLED_BALANCE_ALERT = "Your current payout account still has funds that haven't been paid out, so you can't connect a different Stripe account yet. Try again after your next payout, or contact support if you need help."

  before_action :authenticate_user!

  def stripe
    stripe_connect_data = session[:stripe_connect_data] || {}
    auth_uid = stripe_connect_data["auth_uid"]
    referer = stripe_connect_data["referer"]
    signing_in = stripe_connect_data["signup"]

    unless auth_uid
      flash[:alert] = "Invalid OAuth session"
      return safe_redirect_to settings_payments_path
    end

    merchant_account_owner = if signing_in
      logged_in_user
    else
      authorize [:settings, :payments, current_seller], :stripe_connect?
      current_seller
    end

    stripe_account = Stripe::Account.retrieve(auth_uid)

    case StripeConnectAccountLinker.link(owner: merchant_account_owner, auth_uid:, stripe_account:)
    when :linked_elsewhere
      flash[:alert] = "This Stripe account has already been linked to a Gumroad account."
      return safe_redirect_to referer
    when :unsettled_obligations
      flash[:alert] = UNSETTLED_BALANCE_ALERT
      return safe_redirect_to referer
    when :save_failed
      flash[:alert] = "There was an error connecting your Stripe account with Gumroad."
      return safe_redirect_to referer
    when :inactive
      flash[:alert] = "There was an error connecting your Stripe account with Gumroad."
    else
      log_payout_settings_update_by_non_owner("Stripe account connected") unless signing_in
      flash[:notice] = signing_in ? "You have successfully signed in with your Stripe account!" : "You have successfully connected your Stripe account!"
    end

    success_redirect_path = case referer
                            when settings_payments_path
                              settings_payments_path
                            else
                              dashboard_path
    end

    session.delete(:stripe_connect_data)
    safe_redirect_to success_redirect_path
  end
end
