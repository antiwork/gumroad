# frozen_string_literal: true

class AddFollowerUserIdToFollower < ActiveRecord::Migration
  def change
    add_column :followers, :follower_user_id, :integer
  end
end
