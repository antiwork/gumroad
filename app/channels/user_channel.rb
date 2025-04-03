# frozen_string_literal: true

class UserChannel < ApplicationCable::Channel
  LATEST_COMMUNITY_INFO_TYPE = "latest_community_info"

  def subscribed
    return reject unless current_user.present?
    stream_for "user_#{current_user.external_id}"
  end

  def receive(data)
    case data["type"]
    when LATEST_COMMUNITY_INFO_TYPE
      return reject unless data["community_id"].present?
      community = Community.find_by_external_id(data["community_id"])
      return reject unless community.present?
      return reject unless CommunityPolicy.new(SellerContext.new(user: current_user, seller: current_user), community).show?

      broadcast_to(
        "user_#{current_user.external_id}",
        { type: LATEST_COMMUNITY_INFO_TYPE, data: CommunityPresenter.new(community:, current_user:).props },
      )
    end
  end
end
