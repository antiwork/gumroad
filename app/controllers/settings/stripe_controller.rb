# frozen_string_literal: true

class Settings::StripeController < Sellers::BaseController
  include AuditsPayoutSettingsChanges

  before_action :authenticate_user!, only: [:disconnect]

  def disconnect
    authorize [:settings, :payments, current_seller], :stripe_connect?

    success = StripeMerchantAccountManager.disconnect(user: current_seller)
    log_payout_settings_update_by_non_owner("Stripe account disconnected") if success

    render json: { success: }
  end
end
