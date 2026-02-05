# frozen_string_literal: true

class CommunitiesController < ApplicationController
  layout "inertia"
  before_action :authenticate_user!
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
    seller = User.find_by_external_id!(params[:seller_id])
    community = Community.alive.find_by_external_id!(params[:community_id])
    raise ActiveRecord::RecordNotFound unless community.seller_id == seller.id

    authorize community

    messages_data = paginated_messages(community)
    metadata = scroll_metadata(community, messages_data)

    render inertia: "Communities/Index", props: {
      has_products: -> { current_seller.products.visible_and_not_archived.exists? },
      communities: -> { communities_presenter.communities_props },
      notification_settings: -> { communities_presenter.notification_settings_props },
      selected_community_id: community.external_id,
      messages: InertiaRails.scroll(metadata) { messages_data },
    }
  end

  private
    def communities_presenter
      @communities_presenter ||= CommunitiesPresenter.new(current_user: current_seller)
    end

    def paginated_messages(community)
      cursor = params[:cursor]
      merge_intent = request.headers["X-Inertia-Infinite-Scroll-Merge-Intent"]

      if cursor.present? && merge_intent.present?
        fetch_type = merge_intent == "prepend" ? "older" : "newer"
      else
        cursor = initial_cursor(community)
        fetch_type = "around"
      end

      PaginatedCommunityChatMessagesPresenter.new(
        community: community,
        timestamp: cursor,
        fetch_type: fetch_type,
      ).props
    end

    def initial_cursor(community)
      last_read = LastReadCommunityChatMessage
        .includes(:community_chat_message)
        .find_by(user_id: current_seller.id, community_id: community.id)
      last_read&.community_chat_message&.created_at&.iso8601 || Time.current.iso8601
    end

    def scroll_metadata(community, messages_data)
      cursor = params[:cursor] || initial_cursor(community)

      {
        page_name: "cursor",
        current_page: cursor,
        previous_page: messages_data[:next_newer_timestamp],
        next_page: messages_data[:next_older_timestamp],
      }
    end

    def set_default_page_title
      set_meta_tag(title: "Communities")
    end
end
