# frozen_string_literal: true

# Server-side storage for the store Agent chat, mirroring the conversation + message model that
# hosted chat products (OpenAI, Claude) use: a conversation row per chat, a message row per turn.
# Until now the chat history lived only in the browser's React state, so a refresh lost it.
class CreateAiConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_conversations do |t|
      t.references :seller, null: false
      # Derived from the first user message so the conversation is recognizable in a list.
      t.string :title
      # Soft delete (Deletable concern) so a cleared chat is recoverable/auditable.
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :ai_conversations, [:seller_id, :deleted_at, :updated_at, :id], name: "index_ai_conversations_latest_per_seller"

    create_table :ai_messages do |t|
      t.references :ai_conversation, null: false
      t.string :role, null: false
      # MEDIUMTEXT: assistant replies can embed long product descriptions and generated copy that
      # overflow a 64KB TEXT column.
      t.text :content, size: :medium, null: false
      # Structured payloads attached to a turn — the proposed-change card, the objects the agent
      # looked up, and whether a proposal was applied — persisted so history re-renders faithfully.
      t.json :metadata

      t.timestamps
    end
  end
end
