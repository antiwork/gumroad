# frozen_string_literal: true

class LastReadCommunityChatMessage < ApplicationRecord
  include ExternalId

  belongs_to :user
  belongs_to :community
  belongs_to :community_chat_message

  validates :user_id, uniqueness: { scope: :community_id }

  def self.set!(user_id:, community_id:, community_chat_message_id:)
    record = find_or_initialize_by(user_id:, community_id:)

    if record.new_record? ||
      (record.community_chat_message.created_at < CommunityChatMessage.find(community_chat_message_id).created_at)
      record.update!(community_chat_message_id:)
    end

    record
  end

  def self.unread_count_for(user_id:, community_id:, community_chat_message_id: nil)
    community_chat_message_id ||= find_by(user_id:, community_id:)&.community_chat_message_id

    if community_chat_message_id
      message = CommunityChatMessage.find(community_chat_message_id)
      CommunityChatMessage.where(community_id:).alive
        .where("created_at > ?", message.created_at)
        .where.not(user_id: user_id)
        .count
    else
      CommunityChatMessage.where(community_id:).alive.where.not(user_id: user_id).count
    end
  end
end
