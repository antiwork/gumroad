# frozen_string_literal: true

class CreateCommunityChatMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :community_chat_messages do |t|
      t.references :community, null: false
      t.references :user, null: false
      t.text :content, null: false, size: :long
      t.datetime :deleted_at, index: true

      t.timestamps
    end
  end
end
