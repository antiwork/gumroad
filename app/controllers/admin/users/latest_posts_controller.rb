# frozen_string_literal: true

class Admin::Users::LatestPostsController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    render json: @user.last_5_created_posts
  end
end
