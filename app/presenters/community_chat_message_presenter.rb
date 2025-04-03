# frozen_string_literal: true

class CommunityChatMessagePresenter
  def initialize(message:)
    @message = message
  end

  def props
    {
      id: message.external_id,
      community_id: message.community.external_id,
      content: message.content,
      created_at: message.created_at.iso8601,
      updated_at: message.updated_at.iso8601,
      user: {
        id: message.user.external_id,
        name: message.user.display_name,
        avatar_url: message.user.avatar_url,
        is_seller: message.user_id == message.community.seller_id
      }
    }
  end

  private
    attr_reader :message
end
