# frozen_string_literal: true

# One turn of a store Agent chat (see AiConversation). `content` is the visible text; `metadata`
# carries the structured extras a turn can have — the proposed-change card, the objects the agent
# looked up, and whether a proposal was applied — so a reloaded conversation re-renders exactly as
# it did live (including keeping an already-applied change from being confirmable twice).
class AiMessage < ApplicationRecord
  include ExternalId

  # Bump the conversation's updated_at on every turn so "most recently active" ordering (used by
  # the resume-latest endpoint) follows real usage, not creation time.
  belongs_to :ai_conversation, touch: true

  enum :role, { user: "user", assistant: "assistant" }, prefix: :role, validate: true

  # An assistant turn can legitimately have empty text (the model staged a change and said
  # nothing), so only default the column — presence isn't required.
  before_validation { self.content ||= "" }
end
