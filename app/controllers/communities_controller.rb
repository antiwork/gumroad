# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_default_page_title
  before_action :set_community, only: [:show, :update_notification_settings]
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    presenter = CommunitiesPresenter.new(current_user: current_seller)

    render inertia: "Communities/Index", props: {
      has_products: -> { presenter.props[:has_products] },
      communities: -> { presenter.props[:communities] },
      notification_settings: -> { presenter.props[:notification_settings] }
    }
  end

  def show
    authorize @community

    presenter = CommunitiesPresenter.new(current_user: current_seller)

    render inertia: "Communities/Index", props: {
      has_products: -> { presenter.props[:has_products] },
      communities: -> { presenter.props[:communities] },
      notification_settings: -> { presenter.props[:notification_settings] },
      selectedCommunityId: @community.external_id,
      messages: messages_scroll_prop
    }
  end

  def update_notification_settings
    authorize @community, :show?

    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(permitted_notification_params)

    redirect_to community_path(@community.seller.external_id, @community.external_id),
                notice: "Changes saved!",
                status: :see_other
  end

  private

  def set_default_page_title
    set_meta_tag(title: "Communities")
  end

  def set_community
    seller = User.find_by_external_id!(params[:seller_id])
    @community = Community.alive.find_by_external_id!(params[:community_id])

    raise ActiveRecord::RecordNotFound unless @community.seller_id == seller.id
  end

  def permitted_notification_params
    params.permit(:recap_frequency)
  end

  def messages_scroll_prop
    InertiaRails.scroll(messages_metadata) { paginated_messages_data[:messages] }
  end

  def messages_metadata
    data = paginated_messages_data
    {
      page_name: "cursor",
      previous_page: data[:next_newer_timestamp],
      next_page: data[:next_older_timestamp],
      current_page: message_cursor
    }
  end

  def paginated_messages_data
    @_paginated_messages_data ||= PaginatedCommunityChatMessagesPresenter.new(
      community: @community,
      timestamp: message_cursor,
      fetch_type: message_fetch_type
    ).props
  end

  def message_cursor
    @_message_cursor ||= params[:cursor].presence || last_read_timestamp || Time.current.iso8601
  end

  def last_read_timestamp
    last_read = LastReadCommunityChatMessage.find_by(user: current_seller, community: @community)
    last_read&.community_chat_message&.created_at&.iso8601
  end

  def message_fetch_type
    case request.headers["X-Inertia-Infinite-Scroll-Merge-Intent"]
    when "append" then "older"
    when "prepend" then "newer"
    else "around"
    end
  end
end
