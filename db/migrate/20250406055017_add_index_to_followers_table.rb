# frozen_string_literal: true

class AddIndexToFollowersTable < ActiveRecord::Migration[7.1]
  def change
    change_table :followers, bulk: true do |t|
      t.index [:followed_id, :confirmed_at]
      t.remove_index [:followed_id, :follower_user_id]
      t.remove_index [:follower_user_id, :followed_id]
    end
  end
end
