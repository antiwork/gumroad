# frozen_string_literal: true

class CreateAdminApiAuthorizationCodes < ActiveRecord::Migration[7.1]
  def change
    create_table :admin_api_authorization_codes do |t|
      t.bigint :actor_user_id, null: false
      t.bigint :admin_api_token_id
      t.string :code_hash, limit: 64, null: false
      t.string :code_challenge, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps

      t.index :code_hash, unique: true, name: "idx_admin_api_auth_codes_code_hash"
      t.index [:actor_user_id, :created_at], name: "idx_admin_api_auth_codes_actor_created"
      t.index :admin_api_token_id, name: "idx_admin_api_auth_codes_token"
      t.index :expires_at, name: "idx_admin_api_auth_codes_expires"
    end
  end
end
