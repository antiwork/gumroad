# frozen_string_literal: true

class CreateOauthAuthorizations < ActiveRecord::Migration
  def change
    create_table :oauth_authorizations do |t|
      t.integer :user_id, index: true
      t.integer :provider
      t.string :access_token
      t.string :refresh_token
      t.datetime :expires_at
      t.string :provider_user_id
      t.string :publishable_key
      t.text :raw
    end
  end
end
