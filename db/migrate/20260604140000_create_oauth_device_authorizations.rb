# frozen_string_literal: true

class CreateOauthDeviceAuthorizations < ActiveRecord::Migration[7.1]
  def change
    create_table :oauth_device_authorizations do |t|
      t.integer :oauth_application_id, null: false
      t.integer :resource_owner_id
      t.integer :access_token_id
      t.string :device_code_digest, null: false
      t.string :user_code_digest, null: false
      t.string :scopes, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.datetime :last_polled_at
      t.integer :poll_count, null: false, default: 0
      t.integer :poll_interval_seconds, null: false, default: 5
      t.datetime :approved_at
      t.datetime :denied_at
      t.datetime :consumed_at
      t.string :created_ip_address
      t.string :approved_ip_address
      t.string :denied_ip_address
      t.string :last_poll_ip_address
      t.string :created_user_agent
      t.string :approved_user_agent
      t.string :denied_user_agent
      t.string :last_poll_user_agent
      t.timestamps
      t.index :oauth_application_id
      t.index :resource_owner_id
      t.index :access_token_id
      t.index :device_code_digest, unique: true
      t.index :user_code_digest, unique: true
      t.index [:status, :expires_at]
    end
  end
end
