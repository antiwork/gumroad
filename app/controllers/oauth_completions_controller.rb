# frozen_string_literal: true

class OauthCompletionsController < ApplicationController
  include AuditsPayoutSettingsChanges

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

    merchant_account = MerchantAccount.where(charge_processor_merchant_id: auth_uid).alive
                        .find { |ma| ma.is_a_stripe_connect_account? }

    if merchant_account.present? && merchant_account.user != merchant_account_owner
      flash[:alert] = "This Stripe account has already been linked to a Gumroad account."
      return safe_redirect_to referer
    end

    merchant_account = merchant_account_owner.merchant_accounts.new unless merchant_account.present?

    merchant_account.charge_processor_id = StripeChargeProcessor.charge_processor_id
    merchant_account.charge_processor_merchant_id = auth_uid
    merchant_account.deleted_at = nil
    merchant_account.charge_processor_deleted_at = nil
    merchant_account.charge_processor_alive_at = Time.current
    merchant_account.meta = { "stripe_connect" => "true" }

    if merchant_account.save
      merchant_account_owner.check_merchant_account_is_linked = true
      merchant_account_owner.save!

      merchant_account.currency = stripe_account.default_currency
      merchant_account.country = stripe_account.country
      merchant_account.save!
    else
      flash[:alert] = "There was an error connecting your Stripe account with Gumroad."
      return safe_redirect_to referer
    end

    if merchant_account.active?
      merchant_account_owner.stripe_account&.delete_charge_processor_account!
      log_payout_settings_update_by_non_owner("Stripe account connected") unless signing_in
      flash[:notice] = signing_in ? "You have successfully signed in with your Stripe account!" : "You have successfully connected your Stripe account!"
    else
      flash[:alert] = "There was an error connecting your Stripe account with Gumroad."
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
