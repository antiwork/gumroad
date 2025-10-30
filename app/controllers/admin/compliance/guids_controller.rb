# frozen_string_literal: true

class Admin::Compliance::GuidsController < Admin::BaseController
  include Admin::ListPaginatedUsers

  def index
    user_id = params[:user_id]
    guids = Event.where(user_id:).distinct.pluck(:browser_guid)
    guids_to_users = Event.select(:user_id, :browser_guid).by_browser_guid(guids).
                           where.not(user_id: nil).distinct.group_by(&:browser_guid).
                           map { |browser_guid, events| { guid: browser_guid, user_ids: events.map(&:user_id) } }
    render json: guids_to_users
  end

  def show
    guid = params[:id]
    @title = guid
    @users = User.where(id: Event.by_browser_guid(guid).distinct.pluck(:user_id))
    list_paginated_users users: @users,
                         template: "Admin/Compliance/Guids/Show",
                         legacy_template: "admin/compliance/guids/show"
  end
end
