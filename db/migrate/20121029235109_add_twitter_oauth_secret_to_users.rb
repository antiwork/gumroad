# frozen_string_literal: true

class AddTwitterOauthSecretToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :twitter_oauth_secret, :string
  end
end
