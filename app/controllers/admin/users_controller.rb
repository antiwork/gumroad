# frozen_string_literal: true

class Admin::UsersController < Admin::BaseController
  include Pagy::Backend

  before_action :fetch_user

  helper Pagy::UrlHelpers

  PRODUCTS_ORDER = "ISNULL(COALESCE(purchase_disabled_at, banned_at, links.deleted_at)) DESC, created_at DESC"
  PRODUCTS_PER_PAGE = 10

  def show
    @title = "#{@user.display_name} on Gumroad"
    @pagy, @products = pagy(@user.links.order(Arel.sql(PRODUCTS_ORDER)), limit: PRODUCTS_PER_PAGE)
    respond_to do |format|
      format.html
      format.json { render json: @user }
    end
  end

  def stats
    render partial: "stats", locals: { user: @user }
  end

  def refund_balance
    RefundUnpaidPurchasesWorker.perform_async(@user.id, current_user.id)
    render json: { success: true }
  end

  def verify
    @user.verified = !@user.verified
    @user.save!
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end

  private
    def fetch_user
      if params[:id].include?("@")
        @user = User.find_by(email: params[:id])
      else
        @user = User.find_by(username: params[:id]) ||
                User.find_by(id: params[:id])
      end

      e404 unless @user
    end
end
