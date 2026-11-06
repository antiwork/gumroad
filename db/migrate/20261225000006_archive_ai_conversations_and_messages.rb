# frozen_string_literal: true

# #8928 removed the Store Agent chat. Rename, not drop, so the transcripts survive until a later
# migration drops the archived tables. One raw RENAME TABLE is atomic and metadata only; Rails'
# rename_table and index helpers emit statements that Alterity turns into full pt-osc table copies.
# The guards let a retry pass after an interrupted deploy renamed but did not record the version.
class ArchiveAiConversationsAndMessages < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:ai_conversations)

    execute <<~SQL.squish
      RENAME TABLE ai_conversations TO ai_conversations_archived_20261106,
                   ai_messages TO ai_messages_archived_20261106
    SQL
  end

  def down
    return unless table_exists?(:ai_conversations_archived_20261106)

    execute <<~SQL.squish
      RENAME TABLE ai_conversations_archived_20261106 TO ai_conversations,
                   ai_messages_archived_20261106 TO ai_messages
    SQL
  end
end
