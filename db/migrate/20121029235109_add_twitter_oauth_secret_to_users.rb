# frozen_string_literal: true

class AddTwitterOauthSecretToUsers < ActiveRecord::Migration
  def change
    add_column :users, :twitter_oauth_secret, :string
  end
end
