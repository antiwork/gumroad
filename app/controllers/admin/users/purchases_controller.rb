# frozen_string_literal: true

class Admin::Users::PurchasesController < Admin::BaseController
  before_action :fetch_user

  def index
    @title = "Purchase history for #{@user.display_name}"

    purchases = @user.purchases.includes(:link).order(created_at: :desc)

    if params[:product_title].present?
      escaped_search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:product_title])}%"
      purchases = purchases.left_joins(:link).where("links.name LIKE ?", escaped_search_term)
    end

    @purchases = purchases.page_with_kaminari(params[:page]).per(25)
    @search_query = params[:product_title]
  end

  private
    def fetch_user
      if params[:user_id]&.include?("@")
        @user = User.find_by(email: params[:user_id])
      else
        @user = User.find_by(username: params[:user_id]) ||
                User.find_by(id: params[:user_id])
      end

      e404 unless @user
    end
end
