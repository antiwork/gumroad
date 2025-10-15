# frozen_string_literal: true

class Admin::Users::PayoutInfosController < Admin::Users::BaseController
  before_action :fetch_user

  def show
    render json: {
      payout_info: @user.payout_info
    }
  end
end
