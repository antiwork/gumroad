# frozen_string_literal: true

class CommunityPresenter
  def initialize(community:, current_user:, extras: {})
    @community = community
    @current_user = current_user
    @extras = extras
  end

  def props
    {
      id: community.external_id,
      name: community.name,
      thumbnail_url: community.thumbnail_url,
      seller: {
        id: community.seller.external_id,
        name: community.seller.display_name,
        avatar_url: community.seller.avatar_url,
      },
      last_read_community_chat_message_created_at:,
      unread_count:,
    }
  end

  private
    attr_reader :community, :current_user, :extras

    def last_read_community_chat_message_created_at
      if extras.key?(:last_read_community_chat_message_created_at)
        extras[:last_read_community_chat_message_created_at]
      else
        LastReadCommunityChatMessage.includes(:community_chat_message).find_by(user_id: current_user.id, community_id: community.id)&.community_chat_message&.created_at&.iso8601
      end
    end

    def unread_count
      if extras.key?(:unread_count)
        extras[:unread_count]
      else
        LastReadCommunityChatMessage.unread_count_for(user_id: current_user.id, community_id: community.id)
      end
    end
end
