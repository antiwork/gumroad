# frozen_string_literal: true

class CommunityChatRecap < ApplicationRecord
  belongs_to :community_chat_recap_run
  belongs_to :community, optional: true
  belongs_to :seller, class_name: "User", optional: true

  validates :summarized_message_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :input_token_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :output_token_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :seller, presence: true, if: -> { status_finished? }

  enum :status, { pending: "pending", finished: "finished", failed: "failed" }, prefix: true, validate: true
end
