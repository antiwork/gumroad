# frozen_string_literal: true

class Api::Internal::Communities::ChatMessagesController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_community
  before_action :set_message, only: [:update, :destroy]
  after_action :verify_authorized

  def index
    render json: PaginatedCommunityChatMessagesPresenter.new(community: @community, timestamp: params[:timestamp], fetch_type: params[:fetch_type]).props
  end

  def create
    message = @community.community_chat_messages.build(permitted_params)
    message.user = current_seller

    if message.save
      message_props = CommunityChatMessagePresenter.new(message:).props
      broadcast_message(message_props, CommunityChannel::CREATE_CHAT_MESSAGE_TYPE)
      render json: { message: message_props }
    else
      render json: { error: message.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def update
    if @message.update(permitted_params)
      message_props = CommunityChatMessagePresenter.new(message: @message).props
      broadcast_message(message_props, CommunityChannel::UPDATE_CHAT_MESSAGE_TYPE)
      render json: { message: message_props }
    else
      render json: { error: @message.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    @message.mark_deleted!
    message_props = CommunityChatMessagePresenter.new(message: @message).props
    broadcast_message(message_props, CommunityChannel::DELETE_CHAT_MESSAGE_TYPE)
    head :ok
  end

  private
    def set_community
      @community = Community.find_by_external_id(params[:community_id])
      return e404_json unless @community

      authorize @community, :show?
    end

    def set_message
      @message = @community.community_chat_messages.find_by_external_id(params[:id])
      return e404_json unless @message

      authorize @message
    end

    def permitted_params
      params.require(:community_chat_message).permit(:content)
    end

    def broadcast_message(message_props, type)
      CommunityChannel.broadcast_to(
        "community_#{@community.external_id}",
        { type:, message: message_props },
      )
    rescue => e
      Rails.logger.error("Error broadcasting message to community channel: #{e.message}")
      Bugsnag.notify(e)
    end
end
