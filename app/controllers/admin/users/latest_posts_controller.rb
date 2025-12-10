# frozen_string_literal: true

class Admin::Users::LatestPostsController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    posts = @user.last_5_created_posts.map { |post| Admin::PostPresenter.new(post:).props }
    render json: posts
  end
end
