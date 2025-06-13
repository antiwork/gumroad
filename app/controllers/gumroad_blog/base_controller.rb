# frozen_string_literal: true

class GumroadBlog::BaseController < ApplicationController
  private
    def set_blog_owner!
      owner_username = GlobalConfig.get("BLOG_OWNER_USERNAME", "gumroad")
      @blog_owner = User.find_by!(username: owner_username)
    end
end
