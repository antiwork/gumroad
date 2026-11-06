# frozen_string_literal: true

# The in-product Store Agent chat is removed. Its tables are renamed, not dropped, so the deploy
# stays reversible and the transcripts are preserved. Once the deploy is confirmed good, a later
# migration can drop ai_conversations_archived_20261106 and ai_messages_archived_20261106.
#
# No foreign keys were ever declared on these tables (see db/schema.rb), so only the indexes are
# renamed with them.
class ArchiveAiConversationsAndMessages < ActiveRecord::Migration[7.1]
  def up
    change_table :ai_conversations, bulk: true do |t|
      t.remove_index name: "index_ai_conversations_latest_per_seller"
      t.remove_index name: "index_ai_conversations_on_seller_id"
    end
    remove_index :ai_messages, name: "index_ai_messages_on_ai_conversation_id"

    rename_table :ai_conversations, :ai_conversations_archived_20261106
    rename_table :ai_messages, :ai_messages_archived_20261106
  end

  def down
    rename_table :ai_messages_archived_20261106, :ai_messages
    rename_table :ai_conversations_archived_20261106, :ai_conversations

    change_table :ai_conversations, bulk: true do |t|
      t.index :seller_id, name: "index_ai_conversations_on_seller_id"
      t.index [:seller_id, :deleted_at, :updated_at, :id], name: "index_ai_conversations_latest_per_seller"
    end
    add_index :ai_messages, :ai_conversation_id, name: "index_ai_messages_on_ai_conversation_id"
  end
end
