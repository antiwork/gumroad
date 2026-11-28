# frozen_string_literal: true

class AddPublishingTokenToUserInstagramIdentities < ActiveRecord::Migration[8.1]
  def change
    change_table :user_instagram_identities, bulk: true do |t|
      t.text :encrypted_access_token
      t.datetime :access_token_expires_at
    end
  end
end
