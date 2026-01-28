# frozen_string_literal: true

class AddIndexOnUsersForTwitterOAuthToken < ActiveRecord::Migration[4.2]
  def up
    add_index :users, :twitter_oauth_token
  end

  def down
    remove_index :users, :twitter_oauth_token
  end
end
