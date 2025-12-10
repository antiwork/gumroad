# frozen_string_literal: true

class Admin::Users::GuidsController < Admin::Users::BaseController
  def index
    user = User.find_by_external_id(user_param) || e404
    guids = Event.where(user_id: user.id).distinct.pluck(:browser_guid)

    guids_to_users = Event.select(:user_id, :browser_guid).by_browser_guid(guids)
                          .where.not(user_id: nil).distinct
                          .includes(:user)
                          .group_by(&:browser_guid)
                          .map { |browser_guid, events| { guid: browser_guid, user_external_ids: events.map(&:user_external_id) } }

    render json: guids_to_users
  end
end
