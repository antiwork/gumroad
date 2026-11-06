# frozen_string_literal: true

# The in-product Store Agent chat is removed. Its tables are renamed, not dropped, so the deploy
# stays reversible and the transcripts are preserved. Once the deploy is confirmed good, a later
# migration can drop ai_conversations_archived_20261106 and ai_messages_archived_20261106.
#
# No foreign keys were ever declared on these tables (see db/schema.rb), so only the indexes are
# renamed with them.
#
# MySQL commits DDL per statement, so an interrupted deploy leaves the finished statements applied
# with no migration version recorded. Each step is guarded so the retry resumes instead of failing.
class ArchiveAiConversationsAndMessages < ActiveRecord::Migration[7.1]
  def up
    if table_exists?(:ai_conversations)
      remove_index :ai_conversations, name: "index_ai_conversations_latest_per_seller", if_exists: true
      remove_index :ai_conversations, name: "index_ai_conversations_on_seller_id", if_exists: true
      rename_table :ai_conversations, :ai_conversations_archived_20261106
    end

    if table_exists?(:ai_messages)
      remove_index :ai_messages, name: "index_ai_messages_on_ai_conversation_id", if_exists: true
      rename_table :ai_messages, :ai_messages_archived_20261106
    end
  end

  def down
    rename_table :ai_messages_archived_20261106, :ai_messages if table_exists?(:ai_messages_archived_20261106)
    rename_table :ai_conversations_archived_20261106, :ai_conversations if table_exists?(:ai_conversations_archived_20261106)

    if table_exists?(:ai_messages)
      add_index :ai_messages, :ai_conversation_id, name: "index_ai_messages_on_ai_conversation_id", if_not_exists: true
    end

    if table_exists?(:ai_conversations)
      add_index :ai_conversations, :seller_id, name: "index_ai_conversations_on_seller_id", if_not_exists: true
      add_index :ai_conversations, [:seller_id, :deleted_at, :updated_at, :id], name: "index_ai_conversations_latest_per_seller", if_not_exists: true
    end
  end
end
