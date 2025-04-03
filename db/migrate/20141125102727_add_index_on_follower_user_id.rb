# frozen_string_literal: true

class AddIndexOnFollowerUserId < ActiveRecord::Migration
  def change
    add_index :followers, [:followed_id, :follower_user_id]
    add_index :followers, [:follower_user_id, :followed_id]
  end
end
