# frozen_string_literal: true

class CreateLastReadCommunityChatMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :last_read_community_chat_messages do |t|
      t.references :user, null: false
      t.references :community, null: false
      t.references :community_chat_message, null: false

      t.timestamps

      t.index [:user_id, :community_id], unique: true
    end
  end
end
