# frozen_string_literal: true

class GumroadBlog::BaseController < ApplicationController
  include GumroadBlogHelper

  before_action :ensure_feature_enabled!

  private
    def ensure_feature_enabled!
      return if can_see_gumroad_blog?(logged_in_user)
      raise ActionController::RoutingError, "Not Found"
    end

    def set_blog_owner!
      owner_username = GlobalConfig.get("BLOG_OWNER_USERNAME", "gumroad")
      @blog_owner = User.find_by!(username: owner_username)
    end
end
