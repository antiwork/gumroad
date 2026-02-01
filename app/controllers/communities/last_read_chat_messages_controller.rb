# frozen_string_literal: true

class Communities::LastReadChatMessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_community
  after_action :verify_authorized

  def create
    message = @community.community_chat_messages.find_by_external_id(params[:message_id])
    return e404_json unless message

    params = { user_id: current_seller.id, community_id: @community.id, community_chat_message_id: message.id }
    last_read_message = LastReadCommunityChatMessage.set!(**params)

    render json: { unread_count: LastReadCommunityChatMessage.unread_count_for(**params.merge(community_chat_message_id: last_read_message.community_chat_message_id)) }
  end

  private

  def set_community
    @community = Community.find_by_external_id(params[:community_id])
    return e404_json unless @community

    authorize @community, :show?
  end
end
