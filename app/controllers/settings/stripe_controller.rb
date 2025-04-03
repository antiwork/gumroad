# frozen_string_literal: true

class Settings::StripeController < Sellers::BaseController
  before_action :authenticate_user!, only: [:disconnect]

  def disconnect
    authorize [:settings, :payments, logged_in_user], :stripe_connect?

    render json: { success: StripeMerchantAccountManager.disconnect(user: logged_in_user) }
  end
end
