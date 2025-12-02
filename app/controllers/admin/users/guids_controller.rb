# frozen_string_literal: true

class Admin::Users::GuidsController < Admin::Users::BaseController
  def index
    user = User.find_by_external_id(user_param) || e404
    guids = Event.where(user_id: user.id).distinct.pluck(:browser_guid)

    events_by_guid = Event.select(:user_id, :browser_guid).by_browser_guid(guids).
                           where.not(user_id: nil).distinct.group_by(&:browser_guid)

    user_ids = events_by_guid.values.flatten.map(&:user_id).uniq
    external_ids_by_user_id = User.where(id: user_ids).pluck(:id, :external_id).to_h

    guids_to_users = events_by_guid.map do |browser_guid, events|
      { guid: browser_guid, user_external_ids: events.map { |e| external_ids_by_user_id[e.user_id] } }
    end

    render json: guids_to_users
  end
end
