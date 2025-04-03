# frozen_string_literal: true

class CommunityChatMessage < ApplicationRecord
  include Deletable
  include ExternalId

  belongs_to :community
  belongs_to :user

  has_many :last_read_community_chat_messages, dependent: :destroy

  validates :content, presence: true, length: { minimum: 1, maximum: 20_000 }

  scope :recent_first, -> { order(created_at: :desc) }
end
