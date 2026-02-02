# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_community, only: [:show, :update_notification_settings, :create_message, :mark_message_read]
  before_action :set_message, only: [:update_message, :destroy_message]
  before_action :set_default_page_title

  layout "inertia"

  def index
    authorize Community

    if presenter.first_community
      redirect_to community_path(presenter.first_community.seller.external_id, presenter.first_community.external_id)
    else
      render inertia: "Communities/Index", props: presenter.props
    end
  end

  def show
    authorize @community

    render inertia: "Communities/Index", props: presenter.props(selected_community_id: @community.external_id, messages: -> { messages_props })
  end

  def update_notification_settings
    authorize @community, :show?

    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(notification_settings_params)

    redirect_back fallback_location: community_path(@community.seller.external_id, @community.external_id),
                  notice: "Changes saved!"
  end

  def create_message
    authorize @community, :show?

    message = @community.community_chat_messages.build(message_params)
    message.user = current_seller

    if message.save
      broadcast_message(message, CommunityChannel::CREATE_CHAT_MESSAGE_TYPE)
      redirect_to community_path(@community.seller.external_id, @community.external_id)
    else
      redirect_back fallback_location: community_path(@community.seller.external_id, @community.external_id),
                    alert: message.errors.full_messages.first
    end
  end

  def update_message
    authorize @message, :update?

    if @message.update(message_params)
      broadcast_message(@message, CommunityChannel::UPDATE_CHAT_MESSAGE_TYPE)
      redirect_to community_path(@message.community.seller.external_id, @message.community.external_id)
    else
      redirect_back fallback_location: community_path(@message.community.seller.external_id, @message.community.external_id),
                    alert: @message.errors.full_messages.first
    end
  end

  def destroy_message
    authorize @message, :destroy?

    @message.mark_deleted!
    broadcast_message(@message, CommunityChannel::DELETE_CHAT_MESSAGE_TYPE)
    redirect_to community_path(@message.community.seller.external_id, @message.community.external_id)
  end

  def mark_message_read
    authorize @community, :show?

    message = @community.community_chat_messages.find_by_external_id!(params[:message_id])
    LastReadCommunityChatMessage.set!(
      user_id: current_seller.id,
      community_id: @community.id,
      community_chat_message_id: message.id
    )

    redirect_to community_path(@community.seller.external_id, @community.external_id)
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Communities")
    end

    def set_community
      @community = Community.find_by_external_id!(params[:community_id])
    end

    def set_message
      community = Community.find_by_external_id!(params[:community_id])
      @message = community.community_chat_messages.find_by_external_id!(params[:message_id])
    end

    def notification_settings_params
      params.permit(:recap_frequency)
    end

    def message_params
      params.require(:message).permit(:content)
    end

    def presenter
      @presenter ||= CommunitiesPresenter.new(current_user: current_seller)
    end

    def messages_props
      CommunityMessagesPresenter.new(
        community: @community,
        current_user: current_seller,
        cursor: params[:cursor],
        direction: params[:direction]
      ).props
    end

    def broadcast_message(message, type)
      message_props = CommunityChatMessagePresenter.new(message:).props
      CommunityChannel.broadcast_to(
        "community_#{@community&.external_id || message.community.external_id}",
        { type:, message: message_props }
      )
    rescue => e
      Rails.logger.error("Error broadcasting message to community channel: #{e.message}")
      Bugsnag.notify(e)
    end
end
