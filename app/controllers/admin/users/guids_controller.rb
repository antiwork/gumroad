# frozen_string_literal: true

class Admin::Users::GuidsController < Admin::Users::BaseController
  def index
    if params[:user_id].to_i.to_s == params[:user_id] && user = User.find_by(id: params[:user_id])
      return redirect_to admin_user_guids_path(user.external_id)
    end

    user = User.find_by_external_id(user_param) || e404
    guids = Event.where(user_id: user.id).distinct.pluck(:browser_guid)

    guids_to_users = Event.select(:user_id, :browser_guid).by_browser_guid(guids).
                           where.not(user_id: nil).distinct.group_by(&:browser_guid).
                           map { |browser_guid, events| { guid: browser_guid, user_ids: events.map { |e| User.find(e.user_id).external_id } } }
    render json: guids_to_users
  end
end
