# frozen_string_literal: true

class Admin::Users::StatsController < Admin::Users::BaseController
  include CurrencyHelper

  before_action :fetch_user

  def index
    render json: {
      total: formatted_dollar_amount(@user.sales_cents_total),
      balance: @user.balance_formatted,
      chargeback_volume: @user.lost_chargebacks[:volume],
      chargeback_count: @user.lost_chargebacks[:count]
    }
  end
end
