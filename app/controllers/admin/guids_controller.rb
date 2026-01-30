# frozen_string_literal: true

class Admin::GuidsController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def show
    guid = params[:id]
    set_meta_tag(title: guid)
    @users = User.where(id: Event.by_browser_guid(guid).distinct.pluck(:user_id))
    list_paginated_users users: @users,
                         template: "Admin/Compliance/Guids/Show"
  end
end
