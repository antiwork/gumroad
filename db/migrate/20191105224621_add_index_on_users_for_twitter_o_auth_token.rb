# frozen_string_literal: true

class AddIndexOnUsersForTwitterOAuthToken < ActiveRecord::Migration
  def up
    add_index :users, :twitter_oauth_token
  end

  def down
    remove_index :users, :twitter_oauth_token
  end
end
