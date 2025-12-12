# frozen_string_literal: true

class Admin::Users::MerchantAccountsController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    render json: {
      merchant_accounts: @user.merchant_accounts.as_json(only: %i[id charge_processor_id], methods: %i[alive charge_processor_alive]),
      has_stripe_account: @user.merchant_accounts.alive.charge_processor_alive.stripe.any?
    }
  end
end
