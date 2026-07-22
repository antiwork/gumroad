# frozen_string_literal: true

class Settings::StripeController < Sellers::BaseController
  include AuditsPayoutSettingsChanges

  before_action :authenticate_user!, only: [:disconnect]

  def disconnect
    authorize [:settings, :payments, current_seller], :stripe_connect?

    # StripeMerchantAccountManager.disconnect can report success even when there was no
    # connected Stripe account to remove (a no-op), so only write the audit note when a
    # connected account actually existed before the call. Otherwise the seller's account
    # history would claim a disconnection that never happened.
    had_connected_stripe_account = current_seller.stripe_connect_account.present?
    success = StripeMerchantAccountManager.disconnect(user: current_seller)
    log_payout_settings_update_by_non_owner("Stripe account disconnected") if success && had_connected_stripe_account

    render json: { success: }
  end
end
