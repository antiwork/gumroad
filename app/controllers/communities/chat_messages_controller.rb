# frozen_string_literal: true

class Communities::ChatMessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_community

  def create
    authorize @community, :show?

    message = @community.community_chat_messages.build(permitted_params)
    message.user = current_user

    if message.save
      broadcast_message(message, CommunityChannel::CREATE_CHAT_MESSAGE_TYPE)
      redirect_to community_redirect_path, status: :see_other
    else
      redirect_to community_redirect_path, alert: message.errors.full_messages.first
    end
  end

  def update
    @message = @community.community_chat_messages.find_by_external_id(params[:id])
    if @message
      authorize @message
    end

    if @message.nil?
      head :not_found
    elsif !@message.update(permitted_params)
      redirect_to community_redirect_path, alert: @message.errors.full_messages.first
    else
      broadcast_message(@message, CommunityChannel::UPDATE_CHAT_MESSAGE_TYPE)
      redirect_to community_redirect_path, status: :see_other
    end
  end

  def destroy
    @message = @community.community_chat_messages.find_by_external_id(params[:id])
    if @message
      authorize @message
    end

    if @message.nil?
      head :not_found
    else
      @message.mark_deleted!
      broadcast_message(@message, CommunityChannel::DELETE_CHAT_MESSAGE_TYPE)
      redirect_to community_redirect_path, status: :see_other
    end
  end

  def mark_read
    authorize @community, :show?

    message = @community.community_chat_messages.find_by_external_id(params[:message_id])
    return head :not_found unless message

    mark_read_params = { user_id: current_user.id, community_id: @community.id, community_chat_message_id: message.id }
    LastReadCommunityChatMessage.set!(**mark_read_params)

    redirect_to community_path(seller_id: @community.seller.external_id, community_id: @community.external_id), status: :see_other
  end

  private
    def set_community
      @community = Community.find_by_external_id(params[:community_id])
      head :not_found unless @community
    end

    def permitted_params
      params.require(:community_chat_message).permit(:content)
    end

    def broadcast_message(message, type)
      message_props = CommunityChatMessagePresenter.new(message: message).props
      CommunityChannel.broadcast_to(
        "community_#{@community.external_id}",
        { type: type, message: message_props }
      )
    rescue => e
      Rails.logger.error("Error broadcasting message to community channel: #{e.message}")
      Bugsnag.notify(e)
    end

    def community_redirect_path
      community_path(@community.seller.external_id, @community.external_id)
    end
end
