# frozen_string_literal: true

class Admin::Search::UsersController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def index
    set_meta_tag(title: "Search for #{params[:query].present? ? params[:query].strip : "users"}")
    @users = User.admin_search(params[:query]).order(created_at: :desc)

    list_paginated_users(users: @users, template: "Admin/Search/Users/Index", single_result_redirect_path: ->(user) { admin_user_path(user.external_id) })
  end
end
