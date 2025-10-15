# frozen_string_literal: true

class Admin::Users::StatsController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    render json: @user.stats
  end

  private
    def fetch_user
      @user = User.find_by_external_id(params[:user_id]) || e404
    end
end
