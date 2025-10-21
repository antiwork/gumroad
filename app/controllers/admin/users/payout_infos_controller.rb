# frozen_string_literal: true

class Admin::Users::PayoutInfosController < Admin::Users::BaseController
  before_action :fetch_user

  def show
    render json: @user.payout_info
  end
end
