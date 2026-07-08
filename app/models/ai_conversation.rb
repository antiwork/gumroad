# frozen_string_literal: true

# One store Agent chat for a seller, mirroring the conversation + message model hosted chat
# products (OpenAI, Claude) use. The web Agent endpoints create one per chat and append an
# AiMessage per turn, so the history survives page refreshes instead of living only in React state.
class AiConversation < ApplicationRecord
  include Deletable, ExternalId

  # Long enough to be recognizable in a list, short enough to render as a single line.
  TITLE_MAX_LENGTH = 80

  belongs_to :seller, class_name: "User"
  # Ordered by insertion so the transcript replays in the order the turns happened. `id` breaks
  # ties because two turns can share a created_at second.
  has_many :ai_messages, -> { order(:created_at, :id) }, dependent: :destroy

  # Conversations are titled after the seller's opening message, like hosted chat products do.
  def self.title_from(content)
    content.to_s.strip.truncate(TITLE_MAX_LENGTH).presence
  end
end
