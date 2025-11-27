# frozen_string_literal: true

class Admin::Users::LatestPostsController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    posts = @user.last_5_created_posts.map do |post|
      {
        id: post.external_id,
        name: post.name,
        created_at: post.created_at
      }
    end
    render json: posts
  end
end
