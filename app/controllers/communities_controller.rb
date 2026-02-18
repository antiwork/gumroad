# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_default_page_title
  before_action :set_community, only: [:show]
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    first_community = communities_presenter.first_community
    if first_community
      redirect_to community_path(first_community.seller.external_id, first_community.external_id)
    else
      render inertia: "Communities/Index", props: {
        has_products: -> { communities_presenter.has_products? },
        communities: -> { communities_presenter.communities_props },
        notification_settings: -> { communities_presenter.notification_settings_props }
      }
    end
  end

  def show
    authorize @community

    render inertia: "Communities/Index", props: {
      has_products: -> { communities_presenter.has_products? },
      communities: -> { communities_presenter.communities_props },
      notification_settings: -> { communities_presenter.notification_settings_props },
      selectedCommunityId: @community.external_id,
      messages: messages_scroll_prop
    }
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Communities")
    end

    def communities_presenter
      @communities_presenter ||= CommunitiesPresenter.new(current_user: current_seller)
    end

    def set_community
      seller = User.find_by_external_id!(params[:seller_id])
      @community = Community.alive.find_by_external_id!(params[:community_id])

      raise ActiveRecord::RecordNotFound unless @community.seller_id == seller.id
    end

    def messages_scroll_prop
      InertiaRails.scroll(messages_metadata) { paginated_messages_data[:messages] }
    end

    def messages_metadata
      data = paginated_messages_data
      {
        page_name: "cursor",
        previous_page: data[:next_older_timestamp],
        next_page: data[:next_newer_timestamp],
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
      last_read = LastReadCommunityChatMessage
        .includes(:community_chat_message)
        .find_by(user: current_seller, community: @community)
      last_read&.community_chat_message&.created_at&.iso8601
    end

    def message_fetch_type
      case request.headers["X-Inertia-Infinite-Scroll-Merge-Intent"]
      when "prepend" then "older"
      when "append" then "newer"
      else "around"
      end
    end
end
