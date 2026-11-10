# frozen_string_literal: true

class CreateMcpEventSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_event_subscriptions do |t|
      t.bigint :user_id, null: false
      t.bigint :oauth_application_id, null: false
      t.string :event_name, null: false
      t.json :arguments, null: false
      t.string :callback_url, limit: 2048, null: false
      t.string :secret, null: false
      t.string :key_digest, limit: 64, null: false
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :key_digest, unique: true
      # The default name is over MySQL's 64 characters.
      t.index [:user_id, :event_name, :expires_at], name: "index_mcp_event_subscriptions_on_user_id_event_name_expires_at"
      # The cleanup job deletes by expiry, and deleting an OAuth application deletes its rows.
      t.index :expires_at
      t.index :oauth_application_id
    end
  end
end
