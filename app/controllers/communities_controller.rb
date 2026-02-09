# frozen_string_literal: true

class CommunitiesController < ApplicationController
  layout "inertia"
  before_action :authenticate_user!
  before_action :set_default_page_title
  before_action :set_community, only: [:show]
  after_action :verify_authorized

  def index
    authorize Community

    # Redirect to first community if available
    first_community = communities_presenter.first_community
    if first_community
      redirect_to community_path(first_community.seller.external_id, first_community.external_id)
    else
      render inertia: "Communities/Index", props: {
        has_products: -> { current_seller.products.visible_and_not_archived.exists? },
        communities: -> { communities_presenter.communities_props },
        notification_settings: -> { communities_presenter.notification_settings_props },
      }
    end
  end

  def show
    authorize @community

    cursor = message_cursor
    paginated = paginated_messages_data(cursor)
    scroll_data = messages_scroll_data(paginated, cursor)

    render inertia: "Communities/Index", props: {
      has_products: -> { current_seller.products.visible_and_not_archived.exists? },
      communities: -> { communities_presenter.communities_props },
      notification_settings: -> { communities_presenter.notification_settings_props },
      selected_community_id: @community.external_id,
      messages: InertiaRails.scroll(scroll_data) { paginated[:messages] },
    }
  end

  private
    def communities_presenter
      @communities_presenter ||= CommunitiesPresenter.new(current_user: current_seller)
    end

    def set_community
      seller = User.find_by_external_id!(params[:seller_id])
      @community = Community.alive.find_by_external_id!(params[:community_id])

      raise ActiveRecord::RecordNotFound unless @community.seller_id == seller.id
    end

    def paginated_messages_data(cursor)
      PaginatedCommunityChatMessagesPresenter.new(
        community: @community,
        timestamp: cursor,
        fetch_type: message_fetch_type,
      ).props
    end

    def messages_scroll_data(paginated, cursor)
      {
        page_name: "cursor",
        previous_page: paginated[:next_older_timestamp],
        next_page: paginated[:next_newer_timestamp],
        current_page: cursor,
      }
    end

    def last_read_at
      LastReadCommunityChatMessage
        .includes(:community_chat_message)
        .find_by(user_id: current_seller.id, community_id: @community.id)
        &.community_chat_message
        &.created_at
        &.iso8601
    end

    def message_cursor
      params[:cursor].presence || last_read_at || Time.current.iso8601
    end

    def message_fetch_type
      case request.headers["X-Inertia-Infinite-Scroll-Merge-Intent"]
      when "prepend" then "older"
      when "append" then "newer"
      else "around"
      end
    end

    def set_default_page_title
      set_meta_tag(title: "Communities")
    end
end
