# frozen_string_literal: true

class CommunityChannel < ApplicationCable::Channel
  CREATE_CHAT_MESSAGE_TYPE = "create_chat_message"
  UPDATE_CHAT_MESSAGE_TYPE = "update_chat_message"
  DELETE_CHAT_MESSAGE_TYPE = "delete_chat_message"

  def subscribed
    return reject unless params[:community_id].present?
    return reject unless current_user.present?
    community = Community.find_by_external_id(params[:community_id])
    return reject unless community.present?
    return reject unless CommunityPolicy.new(SellerContext.new(user: current_user, seller: current_user), community).show?

    stream_for "community_#{params[:community_id]}"
  end
end
