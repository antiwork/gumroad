# frozen_string_literal: true

class Api::Internal::Helper::InstantPayoutsController < Api::Internal::Helper::BaseController
  include CurrencyHelper

  before_action :fetch_user


  def index
    balance_cents = @user.instantly_payable_unpaid_balance_cents
    render json: {
      success: true,
      balance: formatted_dollar_amount(balance_cents)
    }
  end

  def create
    result = InstantPayoutsService.new(@user).perform

    if result[:success]
      render json: { success: true }
    else
      render json: { success: false, message: result[:error] }, status: :unprocessable_entity
    end
  end

  private
    def fetch_user
      if params[:email].blank?
        render json: { success: false, message: "Email is required" }, status: :unprocessable_entity
        return
      end

      @user = User.alive.by_email(params[:email]).first
      render json: { success: false, message: "User not found" }, status: :not_found unless @user
    end
end
