# frozen_string_literal: true

class CreateCommunityChatRecaps < ActiveRecord::Migration[7.1]
  def change
    create_table :community_chat_recaps do |t|
      t.references :community_chat_recap_run, null: false
      t.references :community
      t.references :seller
      t.integer :summarized_message_count, null: false, default: 0
      t.text :summary, size: :long
      t.string :status, null: false, index: true, default: "pending"
      t.string :error_message
      t.integer :input_token_count, null: false, default: 0
      t.integer :output_token_count, null: false, default: 0

      t.timestamps
    end
  end
end
