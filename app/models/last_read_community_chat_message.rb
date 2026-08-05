# frozen_string_literal: true

class LastReadCommunityChatMessage < ApplicationRecord
  include ExternalId

  belongs_to :user
  belongs_to :community
  belongs_to :community_chat_message

  validates :user_id, uniqueness: { scope: :community_id }

  def self.set!(user_id:, community_id:, community_chat_message_id:)
    message = CommunityChatMessage.find_by!(id: community_chat_message_id, community_id:)
    record = find_by(user_id:, community_id:)
    unless record
      begin
        record = create!(user_id:, community_id:, community_chat_message: message)
      rescue ActiveRecord::RecordInvalid => error
        record = find_by(user_id:, community_id:)
        raise error unless record && error.record.errors.added?(:user_id, :taken)
      rescue ActiveRecord::RecordNotUnique
        record = find_by!(user_id:, community_id:)
      end
    end

    record.with_lock do
      if record.community_chat_message.created_at < message.created_at
        record.update!(community_chat_message: message)
      end
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
